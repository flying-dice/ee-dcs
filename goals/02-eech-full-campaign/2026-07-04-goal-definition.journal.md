# Journal: Full EECH campaign feature parity — 2026-07-04 (goal-definition)

**Goal:** goals/02-eech-full-campaign/GOAL.md
**Session focus:** Define the goal from EECH source research already completed in goal-01 session

## Log

### 21:20 — Goal defined

User asked to add a goal covering all remaining EECH campaign systems. Goal-01 delivered
the structural skeleton (state, keysites, attack waves, ground forces, win conditions).
Goal-02 covers everything needed to make it feel like a real EECH campaign session:
weapons, regen, reactions, SEAD, CAS, BAI, repair, recon/FOW, artillery, and polish.

EECH source already fully researched — no need to re-read it. Key remaining systems:
- regen.h / rg_updt.c → unit respawn queue
- reaction.c → BARCAP + escort escalation
- create_sead_tasks / create_cas_tasks / create_bai_tasks (highlevl.c) → task variety
- repair_client_server_entity_keysite (ks_updt.c) → base recovery
- update_sector_fog_of_war / get_sector_fog_of_war_value → recon/FOW gate
- create_artillery_strike_tasks (highlevl.c) → fire support

Full autonomy granted — same as goal-01.

## Next steps

1. Start with weapon payloads — query DCS DB for correct CLSIDs per airframe
2. Implement `regen.lua` — FIFO respawn queue, reserve pool, timed respawn
3. Implement `reaction.lua` — BARCAP on S_EVENT_BIRTH of enemy aircraft
4. Extend `attack_waves.lua` — add SEAD, CAS, BAI task types
5. Extend `keysite.lua` — add repair tick (health +X per minute when supplied)
6. Wire supply flights → campaign_state strength increment
7. Implement `recon.lua` — FOW tracking, recon sorties, strike gate
8. Add artillery to `ground_forces.lua`
9. Polish: multiple columns, frontline log, debrief message, phase text

## Open questions

- none

## Follow-ups & improvements

- Carrier/ship operations (EECH had sea units and anchorages) — out of scope for now
- Troop insertion / FARP capture — EECH create_troop_insertion_tasks; could add later
- Human player integration — F10 map markers, radio menu for requesting support
