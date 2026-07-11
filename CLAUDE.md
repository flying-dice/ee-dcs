# CLAUDE.md — dynamic-mission-test

## PRIME DIRECTIVE — align to EECH, never invent fixes (binding, overrides everything below)

This is a **faithful port**, not a game design. The measure of correctness is *fidelity to the EECH
C source*, not whether the campaign "feels right" or "plays well."

- **Every constant, cadence, formula, and behaviour must trace to a specific line in the EECH C
  source** (`E:\eech_source_code`, fork https://github.com/flying-dice/eech_source_code). If you
  cannot cite the C source for a value, you may not set it. No tuning by feel, no invented thresholds,
  no "make it more decisive / faster / balanced" numbers.
- **A user complaint is NOT a change request — it is a bug report of MISALIGNMENT.** When the user
  says "it's too fixed-wing", "captures are too slow", "the sites are too spread out", that means the
  port has DIVERGED from EECH somewhere. The task is to *investigate where the port drifted from the C
  source and realign it* — never to patch the symptom with a home-grown fix.
- **Workflow for any behavioural change:** (1) find the governing EECH C code (highlevl.c, reaction.c,
  ks_dbase.c, force.c, etc.), (2) read what it actually does, (3) make the port match it, (4) cite the
  file:line in the code comment. Use the `eech-fidelity` skill.
- **If EECH's real behaviour genuinely can't be reproduced in DCS**, port the closest faithful proxy
  and document the exact divergence + why in the module header — do not silently substitute your own
  logic.
- Anything in this repo that is a tuned-by-feel value (not C-sourced) is a **latent bug** to be traced
  back to EECH and corrected, not preserved.

## What this project is

A direct port of the Enemy Engaged: Comanche Hokum (EECH) dynamic campaign into DCS
World mission scripting. It boots an entire AI-vs-AI campaign from Lua onto an **empty
Caucasus multiplayer mission**: airbases are discovered from the map, all units are
spawned via `coalition.addGroup`, and the EECH high-level AI (strikes, recon, reaction
chains, ground frontline, helicopter war, logistics, win condition) runs on staggered
timers. The delivery goal is **MP-server playout** — humans join/leave a live campaign
and their kills, losses, and recon matter to the economy (see `goals/03-mp-server-playout/`).

Every module is a faithful port of specific EECH C files. Fork:
https://github.com/flying-dice/eech_source_code — local mirror `E:\eech_source_code`.
**Read the C source before changing any campaign constant or formula.**

## Tooling reality

There is **no standalone `lua-cargo` CLI on PATH**. Build, static analysis, and live
injection are all tools exposed by the **DCS Studio MCP server**
(`http://127.0.0.1:25570/mcp`, see `.mcp.json`). The DCS Studio app must be running for
these tools to exist in a session.

- **Build** — `lua-cargo build` → bundles `Scripts/dynamic-mission-test/main.lua` and the
  21 required modules into `dist/dynamic-mission-test.lua`. Must be **0 warnings**.
- **Static analysis** — `check` — must report **no findings**.
- **Live injection** — `dcs_eval` runs
  `net.dostring_in('server', 'dofile("...dist/dynamic-mission-test.lua")')` in the running
  mission. Re-injection is safe (generation guard, below).

Run build + check after every change; do not commit with warnings or findings.

## Hard guardrails (from goals/03 GOAL.md — binding)

- Mission-scripting environment only: `env.info()` **not** `log.info()`; **no `net.*`**,
  no `os` / `io` / `lfs`. Persistence goes through the DCS Studio bridge
  (`dcs_studio.file` / `dcs_studio.sqlite`), which is sanitization-safe.
- Airbase filter: `ab:getDesc().category == Airbase.Category.AIRDROME` (not `getCategory()`).
- **Verified type names / weapon CLSIDs only** — query the live DB before adding any new
  type or payload. No guessed CLSIDs.
- One module per system, each with a header naming the EECH source file(s).
- **0 warnings / clean `check` after every change.**
- Verify campaign AI constants against the EECH C source before committing.
- **Never replace the single-shot exports** with scheduler calls — the reaction chain
  depends on them: `attack_waves.run_strike`, `attack_waves.run_oca_strike`,
  `cas_bai_sead.run_oca_sweep`, `cas_bai_sead.spawn_sead_against`,
  `cas_bai_sead.spawn_bai_against`, `troop.run_troop_insertion`, `recon.spawn_recon`,
  `reaction.spawn_bda`, `heli_war.spawn_escort` (full context: ANALYSIS §4).
- **Players are first-class**: no campaign code may destroy, recycle, regen, or
  misclassify a player-controlled unit.
- **Superseded constraint — do not "fix" back:** goal-02 said "spawn in-air, never
  TakeOffParking." The design deliberately moved to **ground spawns at the nearest
  friendly base with real TakeOff waypoints** (more EECH-faithful). The `attack_waves.lua:61`
  comment and goal-02 wording are stale (backlog DOC-1). Keep ground spawns.

## Architecture cheat-sheet

- **One singleton:** `campaign_state.lua` returns `M`; `M.S` is *the* shared state table.
  Every module does `local cs = require("campaign_state"); local S = cs.S` and reads/writes
  `S.*` directly. No message bus. `campaign_state` has zero dependencies (root of the
  graph; mirrors EECH SESSION + FORCE).
- **Registries live on `S`:** task registry (`active_tasks` + `register_task`/`get_task`/
  `clear_task`/`has_task_against` — the EECH `entity_is_object_of_task` proxy the whole
  reaction system needs); force-reserve pools (`force_reserve[side][role]`, finite,
  consume-on-spawn / recycle-on-RTB, no production); FOW store (`fow[base][side]`);
  ground-groups registry (`ground_groups[side]`, the standing frontline); keysite map
  (`base_*` = airbases); installations (`keysites[kname]` = non-airbase targets — note the
  naming clash). imap layers are the exception: held module-local in `imap.lua`, reachable
  only via `imap.get()`.
- **Entry point:** `main.lua` (the trigger script) → `require("game_loop").start()`. Note
  `main.lua` also still runs a legacy parallel supply/CAP/patrol layer and carries a dead
  `_G.game_loop` handoff (double-start footgun) — retiring it is backlog P2.
- **Re-injection guard:** `campaign_state.lua` bumps global `_DMT_GEN` each load; every
  scheduled closure captures `my_gen = cs.GENERATION` and self-cancels when it no longer
  matches. Per-process only — a server restart resets all state (persistence is unbuilt).
- **Scheduler pattern:** `game_loop.start()` registers ~23 periodic timers with a
  period + initial offset each, explicitly mirroring EECH `start_high_level_ai()`.

Depth lives in `goals/03-mp-server-playout/ANALYSIS-2026-07-06.md` and `README.md` — read
those rather than duplicating them here.

## Workflow rules

- The `goals/` backlog is authoritative. **Read the latest journal in the active goal
  before working** (`goals/03-mp-server-playout/`). Journals are append-only; use the
  `goal-backlog` skill.
- Coordination model: Fable coordinates; Opus agents implement; per-feature adversarial
  `Agent` review before a cluster is called done. **Never use the Workflow tool.**
- Project skills in `.claude/skills/` — `dev-loop` (build/check/inject cycle),
  `eech-fidelity` (verifying against C source), `live-validation` (in-mission checks).
  Prefer them over ad-hoc procedure.
