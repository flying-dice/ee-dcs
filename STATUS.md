> 25 October 2026: preservation checkpoint only. See HOST-HANDOVER.md for the current review findings and scope; the status below is historical and is not acceptance.

# Campaign TypeScript migration and OSM output

- Goal / health: The TypeScript campaign port passes offline checks and the aircraft lifecycle
  (allocate → spawn → depart → return/loss) has been rebuilt end-to-end against measured live
  DCS behaviour. The remaining gate is a live witness on a freshly generated mission.
- Now: **Epic #17 P0–P4 complete** (sprint 04). Submission outcomes are explicit and reversible;
  parking is leased over real 0-based `Term_Index` stands; recovery/loss settles per airframe
  from the LAND event's own site identity; all five bypass paths and all four virtual-retirement
  timers are on the contract. Full suite green, golden fixtures unchanged, Biome 18/50 (two
  fewer warnings than baseline). Decisions in `docs/bots/decisions/0009` and `0010`.
- Next: **P5 live witness is PENDING and epic #17 stays open.** It needs a freshly generated
  `.miz` — Lua re-injection is explicitly not equivalent. Runbook and required evidence matrix:
  `docs/bots/P5-LIVE-WITNESS-RUNBOOK.md`. It includes a falsifier for the FARP departure-crash
  hypothesis against the recorded pre-P2 control.
- Later: **Backlog card 28 is the most serious open defect** — aircraft losses arrive as
  `S_EVENT_CRASH`, not `S_EVENT_DEAD`, which `regen.make_dead_handler` subscribes to, so **no
  shot-down aircraft has ever enqueued a regeneration replacement** (40/40 aircraft losses were
  CRASH; 0 of 70 DEAD events were aircraft). Needs its own EECH grounding. Also open:
  `keysite.SLOT_CAPACITY` vs physical stands, and four deferred asymmetries — none to be "fixed"
  on internal-consistency grounds.
- Validation: build + 27 core checks + four aircraft-lifecycle legs + campaign smoke at 310/2100 s
  against unchanged golden fixtures. Live evidence and the 305-event control capture in
  `dcs-bugs/aircraft-lifecycle/`; analysis in `docs/bots/LIVE-PROBE-2026-09-22.md`.
  **DCS Studio `check` is UNRUN** — the `/rpc` mission bridge exposes no static-analysis tool;
  Biome was substituted. Do not report it passed.
- Working state: 2026-09-23, branch `main`, uncommitted. `.mcp.json` deleted (its `/mcp` URL
  did not exist); CLAUDE.md "Tooling reality" corrected to the measured `/rpc` bridge.

See [current sprint](docs/bots/sprints/2026-09-22-sprint-04.md).
