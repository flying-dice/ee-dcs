# Journal: EECH-inspired dynamic campaign game loop — 2026-07-04 (module-implementation)

**Goal:** goals/01-eech-game-loop/GOAL.md
**Session focus:** Research EECH source, design module breakdown, implement all modules, deploy and verify

## Log

### 21:00 — EECH source research completed

Read aphavoc/source/ thoroughly. Key systems mapped:

| EECH system | Source files | DCS module |
|---|---|---|
| SESSION root entity | session.c, ss_updt.c | campaign_state.lua |
| FORCE hardware/strength | force.h, fc_funcs.c, imaps.c | campaign_state.lua |
| KEYSITE objectives | keysite.h, ks_funcs.c, ks_updt.c, sc_secfuncs.c | keysite.lua |
| Campaign criteria (fc_updt) | fc_updt.c, force.h | win_condition.lua |
| OCA/strike task gen | highlevl.c, reaction.c, taskgen.h, suitable.c | attack_waves.lua |
| Advance/retreat tasks | highlevl.c, ai_fline.c, order.c | ground_forces.lua |
| start_high_level_ai orchestrator | highlevl.c, update.c | game_loop.lua |

### 21:05 — Background agent's single-file game_loop.lua reviewed

Agent had written a solid 924-line monolith. Good logic but wrong structure. Kept the
core algorithms (rating formula, kill attrition, phase escalation, dynamic difficulty)
and split them into the 5 module files.

### 21:10 — Modules implemented

Files created:
- `Scripts/dynamic-mission-test/campaign_state.lua` — SESSION + FORCE state, shared helpers
- `Scripts/dynamic-mission-test/keysite.lua` — KEYSITE init, damage, scoring, capture
- `Scripts/dynamic-mission-test/win_condition.lua` — fc_updt criteria + kill event handler
- `Scripts/dynamic-mission-test/attack_waves.lua` — OCA strike + escort scheduler
- `Scripts/dynamic-mission-test/ground_forces.lua` — advance/retreat task + column spawn
- `Scripts/dynamic-mission-test/game_loop.lua` — slim orchestrator (start_high_level_ai)

Each module has a header comment naming the exact EECH source files it mirrors.

main.lua updated to `require("game_loop")` and call `game_loop.start()`.
CargoLua.toml: single bundle entry — lua-cargo follows require() chain automatically.

### 21:15 — Build and deploy

`lua-cargo build` output: **7 modules, 0 warnings** — require chain followed correctly.
Injected via `net.dostring_in('server', 'dofile(...)')`.

### 21:16 — Deployment verified in DCS log

Campaign startup confirmed:
- 21 keysites initialised across full Caucasus map (BLUE=10, RED=11)
- Automatic coalition-assigned bases for 7 known bases + auto-split for 14 neutral ones
- Campaign live: BLUE str=73 RED str=76
- All schedulers registered: strikes (T+60s BLUE, T+420s RED), ground (T+180s BLUE, T+630s RED)

Previous supply/CAP/patrol (main.lua) all still working correctly.

Also fixed in this session: SUPPLY_CFG BLUE changed "Hercules" → "C-130" (Hercules is
community mod category=4, not standard airplane category=0; was spawning as wrong type).

### 21:17 — Acceptance criteria status

- [x] Campaign state tracking (base_health, base_owner, strength scores)
- [x] Strength/resource pool (recalc_strength: base_share*50 + avg_health*50)
- [x] Escalation phases (early/mid/late at 15/35 min)
- [x] Attack waves — strike + escort, intelligent target scoring
- [ ] Ground offensives (code deployed, waiting for first column at T+3min)
- [x] Airbase defence (heli CAP + ground patrol from main.lua)
- [x] Logistics (supply flights from main.lua)
- [x] Dynamic balance (losing side gets 25% shorter strike interval)
- [ ] Win condition (code deployed, not yet triggered)
- [x] Modular file structure with EECH backreferences
- [ ] SP/MP compatibility — assumed but not verified with players

## Next steps

1. Wait ~3 min in mission and check log for first ground column spawn
2. Wait ~12 min and check for first strike wave
3. Verify kill event handler fires when aircraft/vehicles are destroyed
4. Verify base health degrades and NEUTRALISED log appears
5. Test win condition (may need a long mission or manual health manipulation)
6. Check: do neutralised airbases get captured by advancing ground columns?
7. Consider: weapon loadouts (aircraft currently spawn with fuel+gun only, no missiles)
8. Consider: BARCAP/intercept reaction when enemy strikes incoming (EECH reaction.c pattern)

## Open questions

- none — full autonomy granted

## Follow-ups & improvements

- Weapon loadouts / CLSIDs — aircraft spawn with empty pylons. Need correct payload tables.
- BARCAP reaction: when enemy strike detected, spawn intercept flight (reaction.c pattern)
- Neutral airbase handling — currently auto-split; option for neutral garrison
- Fog of war: EECH used FOW values to gate strike vs recon. Could add recon flights.
- Regen queue: dead units aren't re-queued yet (EECH regen.h). Strength is proxy only.
- Repair: EECH had REPAIR tasks; bases currently stay at whatever health they reach.
