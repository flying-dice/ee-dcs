---
name: eech-fidelity
description: Use whenever you add or change campaign behaviour, constants, or modules in this EECH→DCS port — how to stay faithful to the EECH C source. Covers where the EECH source lives, the file:line citation rule for every constant, the one-system-per-module convention, the documented structural limits you must NOT "fix", the never-replace run_* export list, and the per-feature adversarial Agent review pattern.
---

# EECH fidelity

This project is a direct Lua port of the EECH (Enemy Engaged Comanche Hokum) dynamic campaign into
DCS mission scripting. Faithfulness to the EECH C source is the point. When in doubt, port what the
C code does — do not invent a "better" behaviour.

## EECH source locations

- **Local checkout:** `E:\eech_source_code`
- **Fork:** https://github.com/flying-dice/eech_source_code

Campaign AI lives under `aphavoc/source/entity/mobile/...`. Key directories/files:

- `highlevl/highlevl.c` — `start_high_level_ai()` timer registration; the `create_*_tasks`
  generators (keysite/OCA strike, CAS, BAI, SEAD, OCA-sweep, artillery, advance/retreat, troop
  insertion/patrol, recon, FW/heli transfer). The master orchestrator.
- `highlevl/reaction.c` — reactive CAP/BARCAP on task assignment, recon/strike follow-on chains on
  task completion.
- `highlevl/imaps.c` — the 4 influence-map layers; balance-of-power inputs.
- `force/force.h`, `force/fc_funcs.c`, `force/fc_updt.c` — the FORCE model: finite reserve hardware,
  spawn-decrement / RTB-recycle, `force_percentage` strength census, campaign criteria.
- `keysite/keysite.h`, `ks_funcs.c`, `ks_updt.c` — keysite ownership/strength/capture/repair.
- `sector/sector.c`, `sc_secfuncs.c` — sectors, FOW.
- `frontl/ai_fline.c` — frontline detection.
- `regen/rg_updt.c`, `regen.c`, `regen.h` — dead-airframe regen queue (reserve-gated).
- `session/session.c`, `ss_updt.c` — SESSION root state.

The **full module→C-source correspondence** is ANALYSIS §5 (`goals/03-mp-server-playout/
ANALYSIS-2026-07-06.md`). Consult it to find which C file backs the Lua module you are editing.

## The citation rule — every constant is verified and cited

Every campaign constant — periods, initial offsets, thresholds, ranges, ratios, counts — **must** be
verified against the EECH C source before you commit it, and cited as `file:line` in the Lua header
or an inline comment. Examples already in the tree: ground advance/retreat cadence "12min =
highlevl.c:250", `KEYSITE_SEAD_RANGE` "4km, EECH MAX_KEYSITE_SEAD_RANGE", strength =
"force_percentage (fc_updt.c:148-161)". Do not introduce a magic number without its citation. If you
cannot find the EECH source for a value, it is a proxy — label it as one (see below), do not pretend
it is faithful.

## Module convention

One system per `.lua` module under `Scripts/ee-dcs/`. The module header names the EECH
source file(s) it ports. State lives in the single `campaign_state.S` singleton (every module does
`local cs = require("campaign_state"); local S = cs.S`) — the only significant exception is imap's
layers, held module-local. Keep new state in `S` unless there is a strong reason not to.

## Documented structural limits — DO NOT "fix" these

DCS cannot expose some EECH substrate. These gaps are **deliberate, documented, faithful proxies** —
do not "discover" them as bugs and rip them out:

- **Road-node adjacency graph** — DCS exposes no road-node adjacency; EECH's node-by-node road
  pathfinding and one-group-per-tick discretisation cannot be reproduced. Keysites-as-nodes with
  continuous vehicle movement is the closest achievable proxy.
- **`INT_TYPE_FRONTLINE` echelon integer** — no DCS equivalent; BAI uses an `is_near_friendly`
  proxy for echelon selection.
- **Per-scenario campaign criteria** — EECH's ~17-criteria set is per-scenario data with no DCS
  equivalent; the port models the 3 global criteria (captured sectors, balance of power, time
  duration). This is intentional.

When you hit one of these, the right move is to keep the proxy and document it, not to redesign.

## Never replace the single-shot `run_*` / `spawn_*_against` exports

The reaction chain (task-completion follow-ons) calls these directly. Deleting, renaming, or
converting them to scheduler calls breaks EECH's completion follow-on behaviour. The full list
(ANALYSIS §4):

- `attack_waves.run_strike(side, log, tname)` and `attack_waves.run_oca_strike(side, log, tname)`
- `cas_bai_sead.run_oca_sweep(side, log)`, `cas_bai_sead.spawn_sead_against(side, aa_group, log)`,
  `cas_bai_sead.spawn_bai_against(side, pos, log)`
- `troop.run_troop_insertion(side, log, tname)`
- `recon.spawn_recon(side, pos, label, log, objective)`
- `reaction.spawn_bda(...)`, `heli_war.spawn_escort(side, pos, log)`

Schedulers (`schedule_*`) are the periodic entry points and are separate — those are called once
from `game_loop.start`. Keep both surfaces intact.

## Per-feature adversarial review pattern (the goal-02 loop)

This is how every feature cluster in goal 02 was hardened, and it works. After you implement a
feature cluster (and it passes build + check clean):

1. **Dispatch a review Agent** (use the `Agent` tool) scoped to that cluster. Give it: the EECH
   source refs (`file:line`) the feature ports, the diff / list of changed modules, and the
   correctness question ("does this match the EECH model in <files>?").
2. The review reliably finds real bugs — reserve-accounting leaks, wrong classifier buckets,
   dedup no-ops, flip-flop logic, indestructible strike magnets were all caught this way.
3. **Fix every finding**, re-run build + check clean, then declare the cluster done. Journal the
   findings and fixes.

**Never use the Workflow tool** — this is a standing directive. Implement directly; use `Agent`
only for this per-feature review.
