---
column: backlog
labels: [docs, bug]
priority: high
updatedAt: 2026-09-21T16:06:45.000Z
---
# Recover the deleted specs/ catalog and goals/ backlog

Commit `7f4879e` ("Add MP Client slots, single-file theatre export, release cleanup") deleted **28
files**, including the entire spec catalog and the entire goal backlog:

- `specs/00-INDEX.md` + 10 subsystem specs (`01-session-lifecycle` … `10-pilots-multiplayer`)
- `goals/01-eech-game-loop/`, `goals/02-eech-full-campaign/`, `goals/03-mp-server-playout/`
  (14 files: 3 GOAL.md, 9 journals, `ANALYSIS-2026-07-06.md`, `GAP-ANALYSIS-2026-07-09.md`)

This leaves dangling references throughout the live codebase and docs:

- **Lua modules cite the deleted specs by ID** — `spec 06 SECTOR-F16` (`frontline.lua:20`),
  `spec 02 FORCE-F6` (`supply.lua`), `spec 07-F9` (`task_board.lua`), `spec 01 F13`, `spec 02 F26`,
  `spec 04 F6` and more. A reader cannot resolve any of them.
- **`CHANGELOG.md:13`** points at `goals/03-mp-server-playout/GAP-ANALYSIS-2026-07-09.md`.
- **`CLAUDE.md`** referenced "ANALYSIS section 4" (now annotated with the git-history location).
- The `goal-backlog` skill in `.claude/skills/` is still installed and documents `goals/` as the
  working convention — but there is nothing for it to operate on.

`GAP-ANALYSIS-2026-07-09.md` is a 214-feature parity audit with per-feature verdicts (FAITHFUL /
PROXY / DIVERGED / DISCONNECTED / MISSING) — 52 faithful, 62 proxy, 17 diverged, 6 disconnected,
24 real gaps, triaged into the "Cluster A–I" fix batches the module headers reference everywhere.
It is the single most valuable fidelity document the project has, and it is the direct prior art
for the 2026-09-21 audit that produced cards 01–04.

`goals/03-mp-server-playout/GOAL.md` was `Status: active` with **unticked P0 acceptance criteria**
(live end-to-end MP validation) when it was deleted — i.e. the backlog was removed mid-flight.

Everything is recoverable: `git show 7f4879e^:<path>`.

**Decision needed from the user** — deletion may have been deliberate release hygiene (that commit
also published the web app, and these are internal planning docs). Options: restore in place;
restore under a `docs/` or internal path; or keep deleted and strip the dangling citations from the
Lua and CHANGELOG instead. Record the outcome as a `decisions/NN-*.md` record.

## Checklist

- [ ] Confirm with the user whether the deletion was intentional
- [ ] Record the outcome as a decision record in `decisions/`
- [ ] Restore `specs/` + `goals/`, or strip every dangling citation from the Lua and CHANGELOG
- [ ] If restoring: reconcile `GAP-ANALYSIS-2026-07-09.md` against the 2026-09-21 audit — several DIVERGED items (invented phases, STRENGTH_SURVIVAL, 200 km bands) have since been fixed
- [ ] If restoring: re-open `goals/03-mp-server-playout` or close it out properly
- [ ] Note that `specs/` paths reference `Scripts/dynamic-mission-test/*` — the old module path, now `Scripts/ee-dcs/*`

## Comments

- **claude** (2026-09-21T16:06:45.000Z): Found while checking whether the audit gaps had been raised in RepoDoc. `git log --diff-filter=D` on `7f4879e` confirms the scope. Flagging as high priority not because the files are lost (they are one `git show` away) but because the working tree currently *lies* — dozens of code comments cite spec IDs that resolve to nothing, which is precisely the doc-drift the PRIME DIRECTIVE exists to prevent.
