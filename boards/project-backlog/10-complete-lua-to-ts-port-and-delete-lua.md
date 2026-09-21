---
column: review
labels: [infra, backend, docs]
priority: high
agent: claude
live: false
status: Awaiting review - full report in card body
updatedAt: 2026-09-21T20:15:00.000Z
---
# Complete the Lua -> TS port and delete the Lua tree

Finish migrating the campaign to `packages/ee-mission` (TypeScript -> TSTL) and remove
`Scripts/ee-dcs/*.lua` as a source tree.

## Current state - the TS port already ships

Investigated 2026-09-21. The migration is much further along than the repo layout suggests:

- **Module coverage is complete.** All 34 Lua modules have a `packages/ee-mission/src/*.ts`
  counterpart, plus 5 TS-only files (`index`, `campaign_types`, `pilot_types`, `dcs.d`,
  `farp_parking`). Nothing in Lua is missing from TS.
- **The shipped artifact is already the TS build.** `dist/ee-dcs.lua` opens with
  `--[[ Generated with https://github.com/TypeScriptToLua/TypeScriptToLua ]]` and contains all
  39 modules. The web app consumes exactly that file and its own comment says it comes from
  `npm run build --workspace ee-mission` (`apps/web/scripts/sync-campaign.mjs:3,15`).
- Module sizes are comparable, so these are real ports, not stubs (e.g. `cas_bai_sead` 1116 lua /
  1087 ts; `keysite` 956 / 1050; `ground_forces` 730 / 832).

So `Scripts/ee-dcs/*.lua` is effectively **legacy source that no longer produces the artifact**.

## The active hazard - two builds, one output path

Both build systems write the same file:

| Build | Output | Configured in |
|---|---|---|
| lua-cargo | `dist/ee-dcs.lua` | `CargoLua.toml:6-7` (`path = "Scripts/ee-dcs/main.lua"`, `name = "ee-dcs.lua"`) |
| TSTL | `dist/ee-dcs.lua` | `packages/ee-mission/tsconfig.json` (`outDir: "../../dist"` -> `E:\ee-dcs\dist`, `luaBundle: "ee-dcs.lua"`) |

Whichever runs last wins, silently. **`CLAUDE.md` still documents `lua-cargo build` as *the* build**,
so following the project's own instructions overwrites the real shipping artifact with a bundle of
the legacy tree. This is a live footgun today, independent of the migration.

`packages/dist/ee-dcs.lua` (4.1 KB, lualib only) looks like a stale output from an earlier `outDir`
and should be removed as part of this.

## Why this matters beyond tidiness

Every fix currently has to be written **twice**. The ramp-start fix (card 09) touched 13 Lua sites
*and* 13 TypeScript sites for one behavioural change. Cards 01, 02, 03, 04, 07 and 08 all describe
the change in Lua terms and will each need the same duplication until this lands - and any
divergence between the trees is a silent correctness bug, since only one of them ships.

## Work

1. **Verify parity before deleting anything.** Module-name coverage is not behavioural parity. Diff
   each Lua module against its TS counterpart for logic drift - especially the EECH constants and
   the `file:line` citations the PRIME DIRECTIVE depends on. Anything that exists only in Lua must be
   ported before the tree is removed.
2. **Confirm the TS bundle runs a full campaign** in a live mission (inject `dist/ee-dcs.lua`, run
   the `live-validation` checklist). Do not delete the Lua on a static diff alone.
3. **Retire the duplicate build.** Delete `CargoLua.toml` + `CargoLua.lock`, make TSTL the only
   producer of `dist/ee-dcs.lua`.
4. **Delete `Scripts/ee-dcs/*.lua`** (git history retains it).
5. **Rewrite the docs.** `CLAUDE.md` "Tooling reality" documents `lua-cargo build` / `check` as the
   gates and the guardrails are written in Lua terms; `README.md`'s module table points at
   `Scripts/ee-dcs/*`. Both need to describe the TS workflow, and the "0 warnings / clean check"
   gate needs a TS equivalent (`tstl` + typecheck + whatever `check` is replaced by).
6. **Decide what replaces `check`.** It is a DCS Studio MCP tool operating on Lua. If it has no TS
   equivalent, say so explicitly rather than leaving a gate in CLAUDE.md that cannot be run.
7. **Re-point the open cards.** 01, 02, 03, 04, 07, 08 cite `Scripts/ee-dcs/*.lua` line numbers;
   either land them first or re-target them at the TS sources.

# REVIEW REPORT — sprint 02, 2026-09-21

Prepared for independent review. Everything below is reproducible from the repo at `E:\ee-dcs`;
no step depends on the originating session.

## STOP — read before committing anything

**The Lua tree is staged for deletion and the TypeScript replacement is NOT in git.**

    git status --short | grep -c "^D "                                 # 35 staged deletions
    git ls-files packages/ee-mission/src/ | wc -l                      # 1  (index.ts only)
    git status --short -uall packages/ee-mission/src/ | grep -c "??"   # 38 untracked
    git ls-files packages/ee-mission/test/ | wc -l                     # 0  (test dir untracked)

Committing the staged state as-is would remove the campaign and add nothing back. The TS sources,
the test harness and the golden fixtures must be `git add`-ed in the same commit as the deletion.
This predates this sprint — the port was authored untracked — but the deletion turns it from untidy
into dangerous. Reviewer: please confirm the add-set before any commit.

## What was asked

"verify no regressions in the port and delete the lua". Deletion was gated on regression evidence,
not performed on assumption.

## Finding 1 (CRITICAL) — SEAD and BAI generators were permanently dead

**Cause.** TSTL types `string.match` as a `LuaMultiReturn`. Used directly inside an expression it
compiles to a *table constructor* — `({string.match(n, p)})` — which is never nil. Every
`string.match(...) !== undefined` test was therefore **always true**, and every `=== undefined`
always false. The pattern is visible in the generated bundle at `dist/ee-dcs.lua:10470`.

**Effect in the shipping bundle:**

| Site | Broken behaviour |
|---|---|
| `cas_bai_sead.ts` `groupFlag()` | every ground group classified `FRONTLINE_FLAG_PRIMARY` |
| `cas_bai_sead.ts` `aaTargets()` | returned 0 targets every pass, so SEAD and BAI generated nothing, ever |
| `supply.ts` `classify_role` / `classify_group` | always returned the first `PREFIX_ROLES` role, so RTB recycling credited the wrong reserve pool |

**Fix.** A documented local `matches()` helper per file, destructuring to force the single-value
form. Call sites now: `cas_bai_sead.ts` 8, `supply.ts` 3, `supply_flight.ts` 2, `troop.ts` 2 (one
helper each). The helper comment states it is a TSTL/Lua-interop fix, not a campaign constant, so
no EECH citation is expected — reviewers applying the PRIME DIRECTIVE should not flag it as missing.

Check: `grep -n -A6 "function matches" packages/ee-mission/src/cas_bai_sead.ts`

## Finding 2 — invented scheduling constant (port regression)

`task_board.ts` carried `INITIAL_ASSIGNMENT_DELAY_SECONDS = 45` where the Lua baseline used
`ASSIGN_CADENCE` (180 s) for the board's *first* assignment pass. TS fired the board twice in a
310 s window where Lua fired once, assigning a spurious helicopter CAS section. Causality proven by
single-constant ablation: patch only that value and the trees converge.

The constant's own comment admitted it was chosen by feel ("made a healthy rotary campaign look
empty") — it was masking card 08 (CAS fires before the spawn queue drains).

Fix: constant deleted, first fire at `ASSIGN_CADENCE`.
Check: `grep -c "INITIAL_ASSIGNMENT_DELAY" packages/ee-mission/src/task_board.ts` returns 0

**Deliberately not over-corrected.** Neither tree matched EECH here: `ks_creat.c:166` randomises the
first pass per keysite (`frand1() * KEYSITE_TASK_ASSIGN_TIMER`, uniform 0 to 180), and only
subsequent intervals use the full cadence (`ks_updt.c:118`). The narrow fix removes an invented
number without inventing a replacement; the real fidelity gap is card 12.

## How the baseline's value was preserved

Deleting the Lua destroys the lua-vs-ts differential — it is a migration instrument. The baseline
was first recorded as golden fixtures:

- `packages/ee-mission/test/golden/baseline-310.json`
- `packages/ee-mission/test/golden/baseline-2100.json`
- `packages/ee-mission/test/golden/core-parity-baseline.lua` (all 27 checks survive deletion)

The harness asserts TS against these on every run; lua legs skip cleanly when the tree is absent.
Re-record deliberately only, via the harness `--emit-golden` flag.

## Evidence

Reproduce with:

    cd /e/ee-dcs && LUA_BIN=/c/lua/lua-5.1.5_Win64_bin/lua npm run test --workspace ee-mission

| Stage | Result |
|---|---|
| Before any fix | DIFFERENTIAL FAILURE both durations; ticks 413 vs 414, 2761 vs 2762 |
| After Finding 2 fix | ticks match; 310 s clean; 2100 s residual recon-name diff |
| After Finding 1 fix | all three comparisons clean at both durations, exit 0 |
| After Lua deleted | 27/27 core-parity vs baseline; golden-vs-ts OK both durations; lua legs SKIP; exit 0 |

**Negative control, run independently by the Lead** (not only by the implementing agent): injecting
`ZZZ-Lead-Canary` into `baseline-310.json` produced `REGRESSION at duration=310s` and exit 1;
fixture restored. The net demonstrably bites.

## Pre-deletion safety check

`git rm -f` was required (9 files had uncommitted changes) and uncommitted work is **not**
recoverable from history. Each Lua-only uncommitted change was confirmed already mirrored in TS
before deleting:

| Change | Confirmed in TS |
|---|---|
| CJTF countries | `config.ts:180` |
| Stock four-slot FARP heliport | `config.ts:546` |
| 13 hot-ramp starts (card 09) | 13 `TakeOffParkingHot` sites across 8 modules |

## What a reviewer should focus on

1. **The commit add-set** — see STOP above. Highest-risk item on this card.
2. **`matches()` correctness** — is destructuring the right fix, and were all affected sites found?
   A repo-wide sweep for other `LuaMultiReturn`-in-expression patterns (not only `string.match`)
   was **not** performed and would be a valuable second pair of eyes.
3. **Whether Finding 1's fix is behaviourally right**, not merely parity-restoring. It reactivates
   two generators; offline parity is necessary, not sufficient. See card 13.
4. **The scope decision**, below.

## Decisions taken

- **Accepted an agent working outside its brief.** The dispatch scoped `task_board.ts` plus tests
  and said not to change campaign behaviour; the agent edited four `src/*.ts` files because the
  brief's premise (an unstable sort) was disproven. Kept, because realigning the port to the
  baseline is the PRIME DIRECTIVE and the alternative was a green suite concealing two dead
  generators. Flagged because scope creep is normally a defect and a reviewer should judge it.
- **No `task_board` tie-breaker added.** The recon-name difference vanished once Finding 1 was
  fixed — it was a symptom, not an unstable sort. A TS-only tie-break would have created
  divergence from the baseline.
- **ROADMAP item 3 live-validation gate waived.** DCS Studio unreachable all session
  (`127.0.0.1:25570`, ConnectionRefused). Waiver and residual risk recorded in
  `docs/bots/sprints/2026-09-21-sprint-02.md`.

## Known gaps — not done, not hidden

- **No live DCS validation, no `check` static analysis.** Studio unreachable. See card 13.
- **The regression net has a blind spot.** It compares spawned group/static names and tick counts.
  Finding 1 evaded it for its whole lifetime because orphaned tasks expired without spawning.
  Adding board-task creation counts to the harness summary would have caught it immediately. Card 13.
- **`CargoLua.toml` / `CargoLua.lock` remain**, now pointing at a deleted path; build cleanup was
  descoped by the user. Side effect: the duplicate-output collision is neutralised, because
  `lua-cargo build` can no longer run and clobber the TSTL artifact.
- **Pre-existing Biome CRLF/format errors** across `packages/ee-mission/src/*.ts`, including files
  nobody touched here. Not introduced by this work.
- **Docs only partially re-pointed.** `CLAUDE.md` has a source-of-truth banner and corrected
  build/test commands; `README.md`'s module table still cites `Scripts/ee-dcs/*`. See card 06.
- **Nothing committed.** 35 deletions staged; all other work sits in the working tree.

## Checklist

- [x] Per-module Lua vs TS behavioural diff — done via the differential harness, not a manual read
- [ ] Confirm every EECH `file:line` citation survived into the TS sources — **NOT verified**, no systematic audit was run
- [ ] Live-validation soak on the TSTL bundle — blocked, DCS Studio unreachable (card 13)
- [ ] Remove `CargoLua.toml` / `CargoLua.lock` — descoped by the user (build process)
- [ ] Delete stale `packages/dist/ee-dcs.lua` — descoped with the build work
- [x] Delete `Scripts/ee-dcs/*.lua` — 35 files, staged
- [~] Rewrite CLAUDE.md and README for the TS workflow — CLAUDE.md done (banner + build/test commands); README module table still cites Lua paths (card 06)
- [ ] Define the TS replacement for the `check` gate, or state none exists
- [ ] Re-point open cards 01-08 at TS paths

## Gates

- [x] port-parity — golden-vs-typescript clean at 310 s and 2100 s; 27 core-parity checks pass; suite exit 0 with the Lua tree deleted (claude, 2026-09-21T19:55:00Z)
- [x] regression-net-bites — negative control: canary injected into baseline-310.json produced REGRESSION + exit 1; fixture restored (claude, 2026-09-21T19:55:00Z)
- [ ] live-validation — BLOCKED, DCS Studio refusing on 127.0.0.1:25570

## Comments

- **claude** (2026-09-21T17:35:00.000Z): Raised at user request. Scoped it by investigating first rather than assuming a greenfield port: the headline is that this is mostly a *cleanup and documentation* job, not a porting job - `dist/ee-dcs.lua` is already TSTL output and the web app already consumes it, so TS is the de-facto source of truth while CLAUDE.md still says Lua is. Flagging the shared `dist/ee-dcs.lua` output path as the one thing worth fixing immediately even if the rest waits: running the documented `lua-cargo build` today silently replaces the shipping TS artifact with a legacy-tree bundle. Parity is asserted from module names and line counts only - I did not diff module bodies, so step 1 is genuine work and the Lua must not be deleted on my say-so.
- **claude** (2026-09-21T19:55:00.000Z): Delivered via sprint 02 (`docs/bots/sprints/2026-09-21-sprint-02.md`). The validation was not a formality — it found **two real regressions** in the TS port that would have shipped silently. (1) `task_board.ts` carried an invented `INITIAL_ASSIGNMENT_DELAY_SECONDS = 45` against the baseline's 180 s, firing the board twice per window; removed. (2) Far worse: 12 sites across `cas_bai_sead.ts`/`supply.ts`/`supply_flight.ts`/`troop.ts` used `string.match(...) !== undefined`, which TSTL compiles to a table constructor that is never nil — so every test was ALWAYS TRUE, every ground group classified PRIMARY, and **the SEAD and BAI generators were permanently dead in the TypeScript port**. Fixed at source with a documented interop helper. Before deleting, the Lua baseline was captured as golden fixtures so the regression net survives; verified it still runs and still bites with the tree gone. Deletion used `git rm -f`, so I first confirmed all three uncommitted Lua-only changes (CJTF countries, stock FARP heliport, the 13 ramp starts) were already mirrored in TS — uncommitted work is not recoverable from history.
- **claude** (2026-09-21T19:55:00.000Z): NOT done here, deliberately: live DCS validation (Studio unreachable), and the CargoLua/TSTL duplicate-output cleanup (user descoped the build process). Note the deletion resolved that collision incidentally — `CargoLua.toml` now points at a path that no longer exists, so `lua-cargo build` can no longer clobber the TSTL artifact. The manifest is still there and should be removed when the build work is picked up.
