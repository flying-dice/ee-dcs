# Goal: EECH-inspired dynamic campaign game loop for DCS

**Status:** complete
**Created:** 2026-07-04
**Owner:** Jonathan Turnock

## Outcome

A DCS dynamic mission script that plays out like an Enemy Engaged (EECH) game session — both in single-player and multiplayer. When a player loads the mission, two coalitions fight a persistent campaign over the Caucasus map: capturing airbases, launching attack waves, running logistics, and escalating until one side wins. It does not need to be 1:1 faithful to EECH but should feel recognisably like the same kind of dynamic campaign loop.

## Acceptance criteria

- [x] **Campaign state** — game tracks which airbases each coalition owns; ownership can change during the mission (`campaign_state.lua`, `keysite.lua`)
- [x] **Strength/resource pool** — each side has a strength score that drains as bases and units are lost and rises with supply; drives win/loss (`campaign_state.recalc_strength`, `win_condition.lua`)
- [x] **Escalation phases** — mission progresses through early/mid/late phases that increase wave size and frequency (`campaign_state.current_phase`, `game_loop.lua`)
- [x] **Attack waves (fixed-wing)** — both sides launch periodic strike packages (strikers + escort) at enemy airbases; target selection is intelligent (not random) (`attack_waves.lua`)
- [x] **Ground offensives** — armoured columns advance toward nearest enemy airbase; can capture neutralised bases (`ground_forces.lua`, `troop.lua`)
- [x] **Airbase defence** — reactive CAP and BARCAP scramble when enemy strike detected; infantry patrol owns bases (`reaction.lua`, `troop.lua`)
- [x] **Logistics** — supply flights between owned airbases sustain hardware inventory; keysite ammo/fuel/repair cycle (`supply.lua`, `keysite_repair.lua`, `transfer.lua`)
- [x] **Dynamic balance** — losing side gets shorter respawn intervals via regen queue (`regen.lua`)
- [x] **Win condition** — mission ends (with log message) when one side captures all bases or reduces enemy strength to zero (`win_condition.lua`)
- [x] **Modular file structure** — implementation split into 16 modules whose boundaries and names mirror the EECH source code; each module has a header comment backreferencing the EECH source file(s) it is inspired by
- [x] **SP and MP compatible** — no player-count assumptions; works when launched with zero human players and when players join mid-mission

## Constraints & guardrails

- Mission scripting environment only: `env.info()` for logging, never `log.info()`
- No TakeOffParking spawns — always in-air at cruise altitude
- Airbase category filter: `ab:getDesc().category == Airbase.Category.AIRDROME` (not `ab:getCategory()`)
- Unit type names must be verified against the live DCS DB before use (confirmed working set: `"F-16C bl.52d"`, `"F-15C"`, `"Su-25T"`, `"Su-27"`, `"MiG-29A"`, `"C-130"`, `"IL-76MD"`, `"AH-64D"`, `"Mi-24V"`)
- Do not break existing main.lua (supply, heli CAP, ground patrol) — game loop builds on top of it
- Each module must have a header comment naming the EECH source file(s) it draws from and a one-line description of the correspondence
- EECH source is at `E:\eech_source_code` — read it before designing modules, don't guess

## Autonomy level

Full autonomy confirmed by user (2026-07-04). User is not in the mission. Agent may:
- Build, inject, and iterate in the live DCS mission at will
- Design and create any module files needed
- Restructure existing files if required
- Deploy to the running mission without asking

Ask before: significantly changing the public API that other agents or the user interact with.

## Context & links

- EECH source: `E:\eech_source_code`
- Project root: `C:\Users\jonat\DCSStudio\my-test-mod`
- Build: `lua-cargo build` → `dist/dynamic-mission-test.lua`
- Inject: `dcs_eval` → `net.dostring_in('server', 'dofile("...dist/dynamic-mission-test.lua")')`
- GitLab for tooling feature requests: https://gitlab.beluga-sirius.ts.net/flying-dice/dcs-studio

## Implemented modules (all 16 PASS, subagent-audited 2026-07-05)

| Module | EECH source |
|---|---|
| `campaign_state.lua` | session.c, force.h |
| `keysite.lua` | keysite.h, ks_funcs.c |
| `supply.lua` | supply.c, order.c |
| `win_condition.lua` | fc_updt.c |
| `attack_waves.lua` | highlevl.c OCA/GROUND_STRIKE |
| `ground_forces.lua` | highlevl.c advance/retreat |
| `game_loop.lua` | highlevl.c start_high_level_ai() |
| `imap.lua` | imaps.c |
| `fog_of_war.lua` | sector.c |
| `frontline.lua` | sector.c / ai_fline.c |
| `regen.lua` | rg_updt.c |
| `keysite_repair.lua` | ks_updt.c |
| `cas_bai_sead.lua` | highlevl.c CAS/BAI/SEAD/OCA Sweep/Arty |
| `troop.lua` | highlevl.c T.I. + patrol |
| `transfer.lua` | highlevl.c FW/HC transfer |
| `reaction.lua` | reaction.c |
