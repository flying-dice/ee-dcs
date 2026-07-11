# Journal: EECH-inspired dynamic campaign game loop — 2026-07-04 (goal-definition)

**Goal:** goals/01-eech-game-loop/GOAL.md
**Session focus:** Define the goal, capture constraints, update autonomy level

## Log

### 20:00 — Goal defined

User requested an EECH-style game loop for DCS. Key constraints captured in GOAL.md:
- Modular structure mirroring EECH source code modules
- Each module backreferences the EECH source file it is inspired by
- Not 1:1 faithful but "reasonable similarity and feature completeness"
- SP and MP compatible
- Existing main.lua (supply/CAP/patrol) is the foundation — don't break it

### 20:05 — Autonomy updated

User confirmed: full control over the running DCS mission. Agent may build, inject, and iterate autonomously without waiting for user input. Mission is running unattended.

### 20:06 — Background agent noted

Agent `ad42b9973271b6c2a` is live, researching EECH source and writing initial game_loop.lua. Its output will be reviewed against this goal spec and refactored into proper module structure once complete.

C-130 fix also deployed this session: SUPPLY_CFG for BLUE corrected from "Hercules" (community mod, category=4) to "C-130" (base DCS, category=0).

## Next steps

1. Wait for agent `ad42b9973271b6c2a` to complete — review its EECH research findings
2. Read EECH source at `E:\eech_source_code` to map source modules → DCS Lua modules
3. Design module breakdown (file names, EECH backreferences, interfaces)
4. Implement each module in order: campaign_state → attack_waves → ground_offensive → win_condition → game_loop (orchestrator)
5. Build + inject after each module; verify in DCS log before moving on
6. Update GOAL.md acceptance criteria checkboxes as each is met

## Open questions

- none — user has granted full autonomy over the running mission

## Follow-ups & improvements

- Neutral airbase handling (A: stay dark, B: auto-split, C: neutral garrison) — deferred from earlier session, worth a follow-up goal or an option in GOAL.md
- Weapon loadouts / CLSIDs for CAP/attack aircraft (currently spawning with no missiles)
- MP: trigger.action.outText() for player-facing messages when objectives are captured
