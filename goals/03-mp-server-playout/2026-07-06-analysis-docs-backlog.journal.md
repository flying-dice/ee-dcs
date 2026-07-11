# Journal: MP-server playout of the EECH campaign port — 2026-07-06 (analysis-docs-backlog)

**Goal:** goals/03-mp-server-playout/GOAL.md
**Session focus:** User directive — analyze current state + abstractions, update the repo with
CLAUDE.md / README.md / supporting skills, and create a backlog of changes toward the goal:
a direct EECH dynamic-campaign port running on a DCS MP server where players can join and
leave mid-campaign. Coordination model: Fable coordinates, Opus agents implement.

## Log
### 09:00 — Session opened, oriented from goals 01 & 02
Read goals/01 (complete, 16 modules) and goals/02 (all clusters A–H implemented + reviewed,
2026-07-05). Outstanding from goal 02: live end-to-end validation (never run in a live mission),
SEAD HARM CLSID verification, documented structural limits (road-node graph, echelon int,
per-scenario criteria). Repo has 22 modules, builds clean via lua-cargo.

### 09:05 — EECH fork located
User gave org dashboard URL; resolved the actual fork via gh api:
**https://github.com/flying-dice/eech_source_code** (local mirror E:\eech_source_code).
Docs will reference both.

### 09:10 — Analysis agent dispatched
Opus agent reading all 22 modules: entry/lifecycle, shared-state model, dependency graph,
public API (run_* single-shots), EECH correspondence, MP-readiness gap analysis (player
join/leave, economy treatment of player units, dedicated-server API surface, persistence,
slot provisioning), code-quality observations. Output feeds CLAUDE.md/README/backlog.

### 09:40 — Analysis complete, saved as ANALYSIS-2026-07-06.md
Opus analysis of all 22 modules done. Headlines: (1) HARD MP BLOCKER — coalition.addGroup
cannot create human slots; empty mission = no flyable slots ever (need pre-baked .miz Client
slots or DCS 2.9 dynamic spawn). (2) No player join/leave lifecycle events handled. (3) No
persistence — in-memory only; dcs_studio.file/sqlite bridge is an unused avenue. (4) regen
dead handler lacks getPlayerName guard (prefix-fragile). (5) map_overlay task arrows never
removed → unbounded mark leak. (6) main.lua carries a legacy second spawn layer + dead
_G.game_loop handoff (double-start footgun). (7) Dup: classify_role/classify_group twin
tables, AC rosters ×6, route literals ×6. API hygiene is clean (no net.*, player-guarded
supply/reaction handlers).

CORRECTION found while verifying the analysis: goal-02 constraint "never TakeOffParking" is
STALE — code deliberately ground-spawns at nearest friendly base with real TakeOff waypoints
(attack_waves.lua:71-75); comment at attack_waves.lua:61 is a leftover. Noted in ANALYSIS
header + backlog DOC-1. Do not "fix" spawns back to in-air.

### 09:50 — Goal 03 defined; backlog written into GOAL.md
goals/03-mp-server-playout/GOAL.md created: P0 (live validation, player slots, MP soak),
P1 (join/leave lifecycle + join brief, player-safe economy, persistence via bridge, mark
hygiene), P2 (single entry point, one classifier, unified keysite registry, shared flight
spawner, imap into S), P3 (SEAD HARM CLSIDs, DOC-1 reconciliation, perf headroom).
Constraints carried from goal 02 with the in-air-spawn one explicitly superseded.

### 09:55 — Tooling fact established
No standalone lua-cargo CLI on PATH; `dcs-studio` CLI invocation launches the full app (did
so accidentally via --help; killed it). Build/check/dcs_eval/DB-query are MCP tools from the
DCS Studio app (http://127.0.0.1:25570/mcp, .mcp.json). App was not running this session →
no MCP tools → live validation impossible today; documented as prerequisite in docs/skills.

### 10:00 — Docs + skills agents dispatched (Opus, parallel)
Agent 1: CLAUDE.md (agent-facing, tight) + README.md full replacement (human-facing).
Agent 2: .claude/skills/{dev-loop,eech-fidelity,live-validation}/SKILL.md runbooks.
Both grounded on ANALYSIS-2026-07-06.md + GOAL.md; coordinator reviews on completion.

### 10:20 — Deliverables reviewed and landed
Both Opus agents completed; coordinator fact-checked all five files against ANALYSIS/GOAL/code:
- **CLAUDE.md** (new, ~92 lines): project statement, tooling reality (MCP-only), hard
  guardrails incl. the full never-replace export list + superseded spawn constraint,
  architecture cheat-sheet, workflow rules (goals/ authoritative, Fable/Opus/review model,
  no Workflow tool, skills pointers). Accurate as written.
- **README.md** (full replacement): concept, campaign-loop prose, 22-module EECH table,
  architecture, running instructions, honest MP status linking goals/03. One fix applied:
  "humans invisible to the economy" reworded to match ANALYSIS §6b (players skipped by
  supply/reaction handlers, lift FOW, count in strength census, targetable).
- **Skills**: .claude/skills/{dev-loop,eech-fidelity,live-validation}/SKILL.md — verified
  frontmatter, commands, timings against the scheduler table; all correct. live-validation
  encodes the regen player-guard gap and the blocked-pending-slots honesty rule.
Memory updated: project_mp_playout.md + reference_dcs_studio_tooling.md added and indexed.

## Session outcome
Repo enablement complete: analysis snapshot (ANALYSIS-2026-07-06.md), goal 03 defined with a
prioritized P0–P3 backlog, CLAUDE.md + README.md rewritten, three runbook skills added,
memory updated. No campaign code changed this session (docs-only), so no build/check run was
required; the tree's last known state stands (22 modules, 0 warnings; check clean).

## Next steps
- **P0-1 Live end-to-end validation** — needs DCS + DCS Studio app running (MCP tools were
  absent all session). Follow .claude/skills/live-validation. First live session should also
  verify the SEAD HARM/Kh-25MP CLSIDs (P3-1) while the DB is reachable.
- **P0-2 Player slot provisioning decision** — pre-baked .miz with Client slots vs DCS 2.9
  dynamic spawn. Needs a design spike + user sign-off (GOAL.md reserves .miz shipping for
  the user). Do this before P1 lifecycle work, which depends on slots existing.
- **P1 quick wins independent of slots** — regen getPlayerName guard, task-arrow mark
  cleanup (wire remove_task_arrow), strength-census human policy decision.
- **P2 consolidation** — single entry point (retire main.lua legacy layer) is the highest-
  value refactor; do it BEFORE persistence so the serialized state model is final-ish.

## Open questions
- Player slots: .miz-with-Client-slots vs DCS 2.9 dynamic spawn — user decision (affects
  whether the "empty mission" premise is relaxed to "empty except Client slots").
- Should human airframes count in the strength census / balance of power? (ANALYSIS §6b —
  a coalition-stacked server can distort the AI economy either way.)
- Persistence storage: dcs_studio.file (serialized Lua) vs dcs_studio.sqlite — pick when
  P1 persistence starts.

## Follow-ups & improvements
- dcs-studio.toml [[files]] manifest only lists main.lua + README.md — decide whether it
  should track all 22 modules + CLAUDE.md, or whether the manifest is tooling-managed.
- goal-02 GOAL.md still contains the superseded "never TakeOffParking" constraint — DOC-1
  (P3) covers reconciling it + the stale attack_waves.lua:61 comment.
- Repo is not under git; consider `git init` + initial commit so future refactors (P2) have
  history to lean on. Not done unilaterally (user hasn't asked).
