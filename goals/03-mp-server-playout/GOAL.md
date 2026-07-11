# Goal: MP-server playout — players join and leave a live EECH campaign

**Status:** active
**Created:** 2026-07-06
**Owner:** Jonathan Turnock

## Outcome

A DCS dedicated multiplayer server runs the EECH dynamic-campaign port continuously from an
empty Caucasus mission bootstrap. Human players can take a flyable slot at any time, fly sorties
inside the ongoing AI-vs-AI war (their kills, losses, and recon matter to the campaign economy),
leave, and rejoin later. The campaign survives a server restart. This is the delivery goal for
the project's stated purpose: a direct port of the EECH dynamic campaign, playable in MP.

## Acceptance criteria

### P0 — playability blockers
- [ ] **Live end-to-end validation** — the port (carryover from goal 02) runs in a live mission:
      inject `dist/dynamic-mission-test.lua`, all schedulers fire, strikes/recon/reaction/ground/
      heli-war/economy behave per the EECH model, no runtime errors over a multi-hour soak
- [ ] **Player slot provisioning** — humans can occupy flyable slots on the campaign mission
      (decision needed: pre-baked `.miz` with Client slots at discoverable airbases vs DCS 2.9
      dynamic spawn; see ANALYSIS §6f). `coalition.addGroup` cannot create human slots — this is
      the hard blocker
- [ ] **MP soak test with players** — at least one session where a human joins mid-campaign,
      flies a sortie, disconnects, and rejoins with the campaign unaffected

### P1 — MP correctness
- [ ] **Player join/leave lifecycle** — handle `S_EVENT_PLAYER_ENTER_UNIT` / `S_EVENT_BIRTH` /
      `S_EVENT_PLAYER_LEAVE_UNIT`: track occupied slots, greet the joining player with a
      situational brief (phase, frontline, own-side strength/reserves) so joining feels like
      entering an ongoing war (ANALYSIS §6c)
- [ ] **Economy is player-safe** — regen dead handler gets an explicit `getPlayerName` guard
      (today prefix-fragile, ANALYSIS §6b); decide + implement whether humans count in the
      strength census (`count_current_hardware`) or are excluded/capped
- [ ] **Persistence across restarts** — campaign state (base_*, force_reserve, ground_groups,
      regen_queue, fow, keysites/installations, active_tasks, imap layers) serialized via the
      DCS Studio bridge (`dcs_studio.file` or `dcs_studio.sqlite`) and restored in
      `game_loop.start()` (ANALYSIS §6e)
- [ ] **F-10 mark hygiene** — task arrows are removed on task completion (`remove_task_arrow`
      currently has zero callers → unbounded mark growth on long sessions, ANALYSIS §6d)

### P2 — architecture consolidation (protects the P0/P1 work)
- [ ] **Single entry point** — retire `main.lua`'s legacy supply/CAP/patrol spawn layer and the
      dead `_G.game_loop` handoff (double-start footgun); `main.lua` becomes trigger shim +
      `require("game_loop").start()` only (ANALYSIS §7)
- [ ] **One group classifier** — merge `supply.classify_role` and `regen.classify_group` into a
      single shared prefix→role table (the two copies must stay in sync by hand today)
- [ ] **Unified keysite registry** — merge airbase `base_*` and installation `S.keysites`
      namespaces behind one accessor with a `kind` field; removes per-consumer
      `is_installation` branching
- [ ] **Shared flight-spawn builder** — one "spawn flight from nearest base" helper owning the
      route literal and the consume/refund reserve pattern (today hand-repeated in ~6 modules;
      a missed refund silently drains a pool)
- [ ] **imap state into `S`** — prerequisite for persistence serialization

### P3 — fidelity + polish leftovers
- [ ] **SEAD anti-radiation loadout** — verify AGM-88/Kh-25MP CLSIDs against the live DB, add
      `PYLON[side].sead`, swap into `spawn_air_strike` (goal-02 carryover)
- [ ] **Doc reconciliation (DOC-1)** — goal-02 GOAL.md constraint "never TakeOffParking" and the
      `attack_waves.lua:61` comment are stale; current design deliberately ground-spawns at the
      nearest friendly base with real TakeOff waypoints. Fix comment; note constraint history
- [ ] **Perf headroom** — cache/stagger the O(bases × groups) enumeration loops (transfer, FOW,
      imap) if the live soak shows tick cost growth (ANALYSIS §7)

## Constraints & guardrails

Carried over from goal 02 (still binding):
- Mission scripting environment only: `env.info()` not `log.info()`; no `net.*`, no `os/io/lfs`
  assumptions (persistence goes through the DCS Studio bridge, which is sanitization-safe)
- Airbase filter: `ab:getDesc().category == Airbase.Category.AIRDROME`
- Verified unit type names / weapon CLSIDs only — query the live DB before adding any new type
- Each system in its own `.lua` module with a header naming the EECH source file(s)
- Build must show 0 warnings after every change; `check` must stay clean
- Campaign AI constants verified against EECH C source (`E:\eech_source_code`, fork:
  https://github.com/flying-dice/eech_source_code) before committing
- Never replace the `run_*` / `spawn_*_against` single-shot exports with scheduler calls —
  the reaction chain depends on them (full list in ANALYSIS §4)

Superseded from goal 02:
- ~~"All aircraft spawned in-air at cruise altitude — never TakeOffParking"~~ — the design moved
  to ground spawns with real TakeOff waypoints (more EECH-faithful); see DOC-1

New for this goal:
- MP dedicated-server compatible APIs only; everything server-authoritative
- Players are first-class: no campaign code may destroy, recycle, regen, or misclassify a
  player-controlled unit
- Coordination model (user directive 2026-07-06): Fable coordinates; Opus agents implement;
  per-feature adversarial Agent review before a cluster is called done. No Workflow tool.

## Autonomy level

Full autonomy as in goals 01/02: build, inject, iterate, read logs, create/modify modules at
will. Ask before: changing how the mission-editor trigger boots the script, shipping/altering a
`.miz`, or changing the public `game_loop.start()` interface.

## Context & links

- Analysis snapshot backing this backlog: `ANALYSIS-2026-07-06.md` (same directory)
- EECH source: `E:\eech_source_code` — fork: https://github.com/flying-dice/eech_source_code
- Prior goals: `goals/01-eech-game-loop/` (complete), `goals/02-eech-full-campaign/`
  (all clusters A–H implemented + reviewed; live validation outstanding → moved here as P0)
- Build: `lua-cargo build` → `dist/dynamic-mission-test.lua`; `check` for static analysis
- Inject: DCS Studio MCP `dcs_eval` → `net.dostring_in('server', 'dofile("...dist/dynamic-mission-test.lua")')`
- DCS Studio tooling issues: https://gitlab.beluga-sirius.ts.net/flying-dice/dcs-studio
- Documented structural limits (not closable in DCS): road-node adjacency graph,
  INT_TYPE_FRONTLINE echelon integer, per-scenario campaign-criteria data
