# CLAUDE.md — ee-dcs

> **Source of truth:** the campaign is TypeScript at `packages/ee-mission/src/*.ts`.
> The `Scripts/ee-dcs/*.lua` tree referenced throughout this document was the migration
> baseline and was **deleted on 2026-09-21**. Where a rule below names a `.lua` path,
> it applies to that module's `.ts` counterpart. Git history retains the Lua at the
> deletion commit.

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
and their kills, losses, and recon matter to the economy.

Every module is a faithful port of specific EECH C files. Fork:
https://github.com/flying-dice/eech_source_code — local mirror `E:\eech_source_code`.
**Read the C source before changing any campaign constant or formula.**

## Tooling reality

There is **no standalone `lua-cargo` CLI on PATH**. Build, static analysis, and live
injection are all tools exposed by the **DCS Studio MCP server**
(`http://127.0.0.1:25570/mcp`, see `.mcp.json`). The DCS Studio app must be running for
these tools to exist in a session.

- **Build** — `npm run build --workspace ee-mission` (typescript-to-lua) → bundles
  `packages/ee-mission/src/index.ts` and its module tree into `dist/ee-dcs.lua`.
  TSTL is the ONLY producer of that file. `lua-cargo`, `CargoLua.toml` and `CargoLua.lock`
  were REMOVED on 2026-09-21 along with the `Scripts/ee-dcs/*.lua` tree they built, so the
  old duplicate-output hazard (two builds writing `dist/ee-dcs.lua`) no longer exists.
- **Tests / regression net** — `npm run test --workspace ee-mission`
  (set `LUA_BIN` if Lua 5.1 is not on PATH). Runs 27 core-parity checks plus campaign
  smoke at 310 s and 2100 s, asserting the world state against **golden fixtures**
  recorded from the Lua baseline before it was deleted
  (`packages/ee-mission/test/golden/`). Must be **green**; a diff here means the port
  has drifted from the baseline. Re-record only deliberately.
- **Static analysis** — `check` (DCS Studio MCP) — must report **no findings**.
- **Live injection** — `dcs_eval` runs
  `net.dostring_in('server', 'dofile("...dist/ee-dcs.lua")')` in the running
  mission. Re-injection is safe (generation guard, below).

Run build + check after every change; do not commit with warnings or findings.

## Hard guardrails (binding)

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
  `reaction.spawn_bda`, `heli_war.spawn_escort` (full context: each function's own header
  comment, plus `goals/03-mp-server-playout/ANALYSIS-2026-07-06.md` — **deleted from the
  working tree** in `7f4879e` "release cleanup"; read it with
  `git show 7f4879e^:goals/03-mp-server-playout/ANALYSIS-2026-07-06.md`).
- **Players are first-class**: no campaign code may destroy, recycle, regen, or
  misclassify a player-controlled unit.
- **Superseded constraint — do not "fix" back:** an earlier design said "spawn in-air,
  never TakeOffParking." The design deliberately moved to **ground spawns at the nearest
  friendly base** (more EECH-faithful). Keep ground spawns. Since 2026-09-21 those are
  **hot ramp starts** — `type="TakeOffParkingHot"` + `action="From Parking Area Hot"`.
  NOTE the DCS trap this fixed: `type` is what the sim honours, so the old
  `type="TakeOff"` + `action="From Parking Area"` pair spawned aircraft **on the runway**
  despite the parking `action` and every comment claiming otherwise. Keep the pair matched.

## Known open misalignments (audit 2026-09-21)

Traced against the C source and **not yet fixed**. These are latent bugs under the Prime
Directive, not accepted design — fix by realigning to the cited source, never by re-tuning.

1. **imap radii are wrong and the C values exist.** `imap.lua:36-37` uses a flat
   `AIR_COVERAGE_RADIUS = 150000` / `IMPORTANCE_RADIUS = 100000` and its header claims these
   are "not per-keysite in our approximation." They **are** per-keysite literals in
   `ks_dbase.c` — airbase 80 km importance / **400 km** air coverage (`ks_dbase.c:103-104`),
   FARP 40/100 km, factory 40/0 km, military base 30/0 km. Air coverage is 2.7x too tight and
   flat across types EECH differentiates. `BASE_DISTANCE` + `IMPORTANCE` feed `keysite.rate_*`,
   so this skews target selection for **every** generator. `installations.FLAGS` already
   transcribes each kind's `ks_dbase.c` row — extend it with the numeric columns
   (`importance`, `importance_radius`, `air_coverage_radius`, `recon_distance`) and make
   `imap.lua` read per-kind.
2. **`keysite.lua:269` is stale**: "all port keysites are airbases (equal importance 1.0)" —
   untrue since `installations.lua` registers non-airbase keysites whose EECH importance is
   0.4-0.8. Re-check `designate_objectives` once (1) lands.
3. **`STRIKE_PACKAGE_SIZE = 2`** (`attack_waves.lua:56`) — the last uncited number in the task
   pipeline. EECH sizes flights via `suitable.c` + the group database, not a literal.
4. **imap scan-range proxies** (`DEFAULT_AIR_SCAN_RANGE 25000`, `DEFAULT_SURF_SCAN_RANGE 15000`,
   threat values `1.0`) — real per-unit `FLOAT_TYPE_*_SCAN_RANGE` values exist in the vehicle DB.
5. **200 km influence radius** (`cas_bai_sead.lua:142`) — the last survivor of the invented
   fixed-km band that `frontline.lua` already replaced with Gabriel adjacency.

Everything else audited clean: all 12 `create_*_tasks` cadences/offsets match `highlevl.c:218-268`
exactly, the `CREATE_*_TASK_COUNT` / `MIN_TASK_CREATION_RATIO` gates match `highlevl.c:88-100`, the
escort threshold matches `assign.c:598-627`, croute's AIR profile matches `croute.c:128-134`, and
the keysite supply-usage + flag rows match `ks_dbase.c`. The remaining proxies (road-node graph,
repair-task latency, cargo entities, single global task-board pass) are documented structural
limits — do **not** "fix" those back.

## Architecture cheat-sheet

- **One singleton:** `campaign_state.lua` returns `M`; `M.S` is *the* shared state table.
  Every module does `local cs = require("campaign_state"); local S = cs.S` and reads/writes
  `S.*` directly. No message bus. `campaign_state` has zero dependencies (root of the
  graph; mirrors EECH SESSION + FORCE).
- **Registries live on `S`:** task registry (`active_tasks` + `register_task`/`get_task`/
  `clear_task`/`has_task_against` — the EECH `entity_is_object_of_task` proxy the whole
  reaction system needs); force-reserve pools (`force_reserve[side][role]`, finite,
  consume-on-spawn / recycle-on-RTB, plus the production economy in `supply.lua`
  — `S.production` crates from factory/refinery/port keysites convert to reserve
  replacement); FOW store (`fow[base][side]`);
  ground-groups registry (`ground_groups[side]`, the standing frontline); keysite map
  (`base_*` = airbases); installations (`keysites[kname]` = non-airbase targets — note the
  naming clash). imap layers live on `S` as well (`S.imap.raw` / `S.imap.nrm`, moved there in
  Wave 1 for persistence); `imap.lua` holds module-local *references* into them and they stay
  reachable only via `imap.get()`.
- **Entry point:** `main.lua` (the trigger script) is a thin shim: install `spawn_queue`
  interception → `reset.nuke()` → `config.load_and_validate()` → a single
  `require("game_loop").start()` → `spawn_queue.schedule_drain()`. The legacy parallel
  supply/CAP/patrol layer and the `_G.game_loop` double-start handoff were **deleted** in
  Cluster H — do not reintroduce a second start path.
- **Re-injection guard:** `campaign_state.lua` bumps global `_DMT_GEN` each load; every
  scheduled closure captures `my_gen = cs.GENERATION` and self-cancels when it no longer
  matches. Per-process only — a server restart resets all state (persistence is unbuilt).
- **Scheduler pattern:** `game_loop.start()` registers ~23 periodic timers with a
  period + initial offset each, explicitly mirroring EECH `start_high_level_ai()`.

Depth lives in `README.md` — read it rather than duplicating it here.

## Workflow rules

- Coordination model: Fable coordinates; Opus agents implement; per-feature adversarial
  `Agent` review before a cluster is called done. **Never use the Workflow tool.**
- Project skills in `.claude/skills/` — `dev-loop` (build/check/inject cycle),
  `eech-fidelity` (verifying against C source), `live-validation` (in-mission checks).
  Prefer them over ad-hoc procedure.
