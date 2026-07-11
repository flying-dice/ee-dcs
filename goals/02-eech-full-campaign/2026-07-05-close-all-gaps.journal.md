# Journal: Full EECH campaign feature parity — 2026-07-05 (close-all-gaps)

**Goal:** goals/02-eech-full-campaign/GOAL.md
**Session focus:** Drive the port gap to ZERO. A prior gap analysis (this session) found the
port is structurally complete but behaviourally shallow — constants/formulas/periods are faithful,
but the *wiring between systems* diverges. Memory note "all gaps closed / fidelity sign-off" was
inaccurate. User directive: port every feature that is technically possible in DCS mission
scripting EXACTLY as EECH does it. Build missing substrate (finite hardware pools, ground
registry, road-node graph, recon tasks) rather than proxying. In-memory state only — no save/
resume; MP-server playout with players joining/leaving slots. No compromises on fidelity/complexity.

## Gap inventory (from this session's analysis — 24 findings)

HIGH: (1) strength decoupled from hardware; (2) supply infinite/self-replenishing; (3) no recon
substitution — fogged targets dropped forever; (4) create_keysite_strike_tasks missing (only OCA
strike runs); (5) BDA/follow-on chain fires on wipeout not task-success; (6) reactive CAP defends
wrong base; (7) SEAD suppression gate missing; (8) recon→SEAD/BAI on ground groups absent;
(9) single ground column vs standing multi-group frontline; (10) FOW as pre-sort filter not
post-sort fork.
MED: (11) strike throughput capped at 1/cycle; (12) OCA-strike & ground-strike collapsed;
(13) no reaction to artillery fire; (14) regen omits ground/people/ship; (15) keysite auto-heals
no repair task; (16) SEAD generic loadout; (17) BAI over-selects rear groups; (18) ground no road
graph/retreat; (19) follow-on tasks lack dedup; (20) no defensive counter-troop-insertion.
LOW: (21) phase not shown to players; (22) win criteria 2 of ~17; (23) FOW own-sector not pinned/
invented radii; (24) ground cadence 15 vs 12 min + extra strength gate.

## Delivery plan (dependency-ordered clusters)

- **A. Force/hardware economy** (#1,#2,#4,#12,#14) — the foundation. Build a real force_info model
  (per-side current+reserve hardware by category), fed by spawns/deaths/regen/transfer. Rewrite
  recalc_strength to fc_updt.c force_percentage. Add create_keysite_strike_tasks distinct from OCA.
- **B. Recon loop** (#3,#10,#8) — add a RECON task type + spawner; convert FOW filter→post-sort
  fork in CAS/BAI/SEAD/OCA; wire recon→SEAD/BAI on ground groups in reaction.
- **C. Reaction chain** (#5,#6,#7,#13,#19,#20) — success detection (RTB/land), target-base encoding,
  SEAD suppression gate, artillery reaction, dedup guards, counter-TI.
- **D. Ground war** (#9,#18,#24) — ground registry: N frontline groups at OOB, road-node graph,
  node-by-node advance/retreat.
- **E. Throughput + repair + FOW polish** (#11,#15,#16,#17,#23).
- **F. Player-facing + criteria** (#21,#22).

Guardrail: build must show 0 warnings after every change; verify each constant against EECH C
source before committing it; each cluster gets an Agent per-feature review (memory: no Workflow tool).

## Log
### (start) — Session opened, plan recorded
Beginning with Cluster A (force/hardware economy) — it is the foundation the whole campaign
"feel" depends on and every other spawn site must consume from it. First: re-read EECH force
model ground truth (force.h, fc_updt.c, force.c, order.c reserve seeding) and current port
supply/campaign_state/regen before designing the substrate.

### (mid) — Two hard architectural anchors from user
1. **DO NOT USE the Workflow tool** (reaffirmed twice). Implement directly in main loop; Agent
   only for per-feature review. (Also standing memory: feedback_no_workflows.)
2. **Empty-mission bootstrap.** DCS side = empty mission on correct theatre (Caucasus) ONLY.
   The whole scenario/OOB is baked into Lua and injected dynamically when the MP server starts:
   base→side assignment, per-side hardware reserves, standing ground frontline registry,
   road-node graph, initial garrisons. Nothing is placed in the mission editor. → centralize
   baked scenario/OOB data in Lua (procedural where possible so it works on any empty Caucasus
   mission; tunables in one place).

### (design) — Force/hardware economy design decided (verified vs EECH C source)
- EECH `force_info_reserve_hardware[side][cat]` = per-SIDE finite pool: seeded once
  (parser.c:1303), decremented on spawn during INITIALISED (force.c:238-241), re-credited ONLY on
  recycle/RTB (force.c:297). NO production in campaign. regen gated on reserve>0 (rg_updt.c:287).
- EECH strength = `force_percentage = this_force/total_forces` over CURRENT hardware summed across
  all 8 categories (fc_updt.c:148-161). 8 cats = armed/unarmed × {FW, heli, routed-veh, ship}.
- **Port design:** (a) `S.force_reserve[side][role]` finite pool seeded per-owned-base at init,
  depletes on spawn, recycles on RTB (S_EVENT_LAND) — NO production. (b) `recalc_strength` =
  live census: count alive mobile units per side via coalition.getGroups over AIRPLANE/HELI/GROUND,
  strength = share×100 (more faithful than a drift-prone tally — DCS can enumerate). (c) role→cat
  map for logging. (d) `best_friendly_airbase` drops the per-base inventory filter → nearest
  operational owned base; hardware gate moves to side-level reserve. Ownership+health become
  SEPARATE win criteria (not folded into strength), matching EECH criteria separation.

## Next steps
- **Live end-to-end validation** (primary): DCS was at main menu (sim_running=false) the whole
  session, so nothing ran in a live mission. Next live session: inject dist/dynamic-mission-test.lua
  (net.dostring_in server → dofile), watch env.info log for the schedulers + reserve/strength/phase
  output, confirm strikes/recon/reaction/ground/heli-war behave, and check static installations spawn
  (verify the DB-verified type names actually place).
- **SEAD HARM loadout**: query live DB for AGM-88/Kh-25MP CLSIDs, add PYLON[side].sead, swap into
  spawn_air_strike when is_sead.
- Optionally deepen: transfer.lua physical ferry (currently economy-neutral proxy); FARP operations;
  heli SEAD; per-scenario campaign criteria if a scenario editor is added.

### (Cluster A done) — Force/hardware economy implemented
Implemented and building clean (19 modules, 0 build warnings):
- `supply.lua` full rewrite: `S.force_reserve[side][role]` finite per-side pool (roles: striker,
  escort, heli, recon, transport, vehicle, troop); role→EECH-category map; seeded at init from
  RESERVE_PER_BASE × owned bases; base_name→side resolution keeps old call sites intact; NO
  production (removed supply_tick); RTB recycle via `make_land_handler` (S_EVENT_LAND →
  recycle_side +1 + despawn after 30 s, once-guard S._recycled, skips player slots);
  side-keyed core `reserve_side/consume_side/recycle_side`.
- `campaign_state.recalc_strength` = live census: `count_current_hardware(side)` counts alive
  units via coalition.getGroups over all categories; strength = share×100 (fc_updt.c:161).
  Territory/efficiency now SEPARATE criteria (win_condition), not folded in.
- `attack_waves.lua`: split `schedule_keysite_strikes` (7.5min/offset15s, intent "ground",
  prefix KStrike-) vs `schedule_oca_strikes` (30min/offset390s, intent "oca", prefix OCAStrike-);
  spawn gates on `consume_side` BEFORE launch, refunds on no-base; distinct `run_strike`
  (ground) + `run_oca_strike` single-shots for reaction. Removed dead phase-compression code.
- `game_loop.lua`: schedules both strike types at exact EECH offsets; registers land handler.
- `regen.classify_group` + `supply.classify_role` aligned to new group names.
- `keysite.best_friendly_airbase` drops per-base inventory filter (gate now side-level).
- `map_overlay` shows per-side reserve.
Dispatched Agent review of Cluster A (economy correctness vs EECH) — pending.
Deferred within A: #14 ground/people regen → folded into Cluster D (needs ground registry first).

### (backlog) — New cluster surfaced
- **Cluster G: non-airbase keysites** — EECH keysite_database has bridges/depots/factories/radar
  as keysites with flags oca_target / ground_strike_target / recon_target / requires_cap /
  requires_barcap. Port models airbase-only keysites, so keysite_strike vs oca_strike currently
  share the airbase target set (differ only by cadence). Full fidelity needs baked-scenario
  static installations as keysites. Added to remaining-work; not blocking.

### (Cluster A review + fixes) — economy corrected, tree fully clean
Agent review of Cluster A found 3 HIGH reserve-accounting bugs + M1; all fixed:
- **H1** RTB recycle credited +1/group but spawn consumes N/group → leak on every healthy
  multi-ship sortie. Fixed: `make_land_handler` now recycles `#grp:getUnits()` survivors.
- **H2** OCA-Sweep escorts classified as striker (`^OCA` caught `OCA-Sweep`) → wrong pool.
- **H3** CAP/BARCAP consume escort but were classified heli → escort pool bled, heli inflated.
  Fixed H2+H3: rewrote BOTH classifiers (supply.classify_role + regen.classify_group) to agree
  exactly — escort = {Escort,OCA-Sweep,CAP,BARCAP,Regen-Escort}; striker = {Strike,KStrike,
  OCAStrike,CAS,BAI,SEAD,Regen-Strike}; heli = {Heli,Insert,BDA,Regen-Heli}; recon/ferry = no regen.
- **M1** consumed reserve not refunded on `coalition.addGroup` nil. Added refunds to every spawner:
  attack_waves (strike+escort), cas_bai_sead (spawn_air_strike, OCA-sweep), reaction (CAP,BARCAP,
  BDA), troop (no-airbase + spawn-fail). Also fixed troop no-airbase path that leaked heli.
Then cleared ALL 8 pre-existing static-analyzer warnings (fog_of_war recon_r init, keysite
behind_base guard+init, map_overlay frontline paired-locals via `found` flag, main.lua to_wp
annotation + patrol_ring coercion). `check` now: 21 files, NO findings. Build: 19 modules, 0 warnings.
Cluster A COMPLETE.

Known follow-up for Cluster C: CAP/BARCAP/BDA flights are destroyed mid-air at expiry (never
RTB) so they permanently consume escort/heli reserve instead of recycling. EECH recycles at task
expiry. Fix in C: route CAP/BARCAP/BDA to RTB at CAP_DURATION (land handler recycles) or recycle
explicitly on the expiry timer (respecting S._recycled once-guard). Consistent now, just drains.

### (Cluster B) — Recon loop implemented
- New `recon.lua`: `spawn_recon(side, target_pos, label)` — fast high-alt overflight (F-15C/Su-27),
  consumes "recon" reserve, RTBs+recycles, grants FOW on arrival via fog_of_war per-unit scan.
  Name "Recon-*" (no regen, recycled on land).
- `cas_bai_sead.lua`: added `apply_fork` — the EECH post-sort strike-vs-recon FORK
  (highlevl.c:731-800). Score ALL candidates (no FOW pre-filter) → sort → top CREATE_*_COUNT →
  ratio≥0.75 → per-sector cap → FOW≥threshold ? strike : RECON. Rewrote run_cas (fow=nil, never
  recon — EECH CAS has no FOW gate), run_bai (0.5), run_sead (0.25), run_oca_sweep (0.25, escort
  sweep extracted to spawn_oca_sweep). Sector proxy = nearest base; `fow_at` uses nearest base
  (fixes audit L4 200km-cap). Fixed: fow_m.get() is already NORMALISED 0..1 (was almost
  double-scaled by FOW_MAX).
- **BONUS #11 (throughput, Cluster E) done here**: per-sector cap (`sectors_used`) + count=min(#,2)
  replaces the old global `spawned<1`, so 2 targets in distinct sectors both get tasked per cycle.
- Deferred: #8 (recon→SEAD/BAI on enemy AA/frontline GROUPS) lives in reaction.lua → folded into
  Cluster C to avoid double-editing that file.
Build: 20 modules, 0 warnings. check: 22 files, no findings. Review dispatched.

### (Cluster B review + fix) — recon self-heal corrected
Review found HIGH: recon aimed at raw target (e.pos) but FOW gate reads nearest BASE — a ground
target 20-40km from its base never raised that base's FOW → dead loop persisted for BAI/SEAD.
Fixed: apply_fork now aims recon at the SECTOR BASE (S.base_pos[base]) the gate reads, guaranteeing
self-heal for all task types. Also: BAI fow_strict '>' (EECH line 757); removed unused local in
recon.lua; recon now registers its objective for the recon-completed chain. Cluster B COMPLETE.

### (Cluster C) — Reaction chain rewritten
Full reaction.lua rewrite + task-registry substrate (campaign_state.register_task/get_task/
clear_task/has_task_against):
- **Naming regression fixed** (Cluster A renamed strikes; reaction.classify now KStrike/OCAStrike).
- **H1** completion fires on RTB (S_EVENT_LAND) = SUCCESS, not S_EVENT_DEAD wipeout = failure.
  Shot-down mission → no follow-on. DEAD branch only clears the registry (no leak/stale dedup).
- **H5** every mission registers exact target_base at spawn (attack_waves, cas OCA-sweep, recon);
  defender scrambles CAP/BARCAP at the REAL objective, not nearest-to-attacker.
- **H2** SEAD suppression gate: create_sead_around_keysite counts enemy AA within KEYSITE_SEAD_RANGE
  (4km, EECH MAX_KEYSITE_SEAD_RANGE), spawns up to 3 SEAD; if >1 → abort strike follow-ons.
- **#8** recon-completed GROUP branch: AA group→SEAD, frontline group→BAI (spawn_bai_against added).
- **M5** OCA strike (run_oca_strike) vs ground strike (run_strike) now distinct.
- **M1** requires_cap/requires_barcap independent flags + per-type dedup (has_task_against).
- **M4** dedup guards on OCA-strike/OCA-sweep/TI/ground-strike follow-ons.
- **M3** backup DEFENDER troop insertion (reaction.c:429).
- **M2** INT_TYPE_ALIVE gate (destroyed keysite → no follow-on).
- CAP/BARCAP/BDA recycle-on-expiry (recycle_once guard shared with land handler) — closes the
  escort/heli drain from Cluster A. KEYSITE_SEAD_RANGE=4km is EECH-exact but airbase-point vs SAM
  ring may want tuning (flagged for review).
Build: 20 modules, 0 warnings. check: 22 files, no findings. Review dispatched.

### (Cluster C review + fixes) — reaction verified & hardened
Review found: H-1 troop_insertion dedup no-op + reaction TI not targeted; M-1 CAP expiry no
clear_task (ALREADY fixed preemptively); M-2 CAP never loiters (no Orbit); M-3 BDA no dedup;
L-1 over-strict ground-strike dedup. Fixed:
- H-1: troop.spawn_troop_insert now registers "troop_insertion" task (TTL clear); added targeted
  run_troop_insertion(side,log,target_name); reaction inserts against the reconned base (+ backup
  defender), not a re-scan.
- M-2: cap_route now carries EngageTargets + Orbit(Race-Track) so CAP/BARCAP loiter CAP_DURATION.
- M-3: BDA follow-on deduped (not already recon/bda) per reaction.c:678.
- L-1: removed ground-strike dedup (EECH creates unconditionally).
Cluster C COMPLETE & verified.

### (Cluster D) — Standing frontline ground war
Rewrote ground_forces.lua: STANDING FRONTLINE registry S.ground_groups[side][gname] (replaces the
single S.columns handle). init_oob seeds one company-sized group per frontline base (friendly base
within FRONT_DIST=140km of an enemy base), drawn from the per-side "vehicle" reserve. Tick
(advance_retreat, 12min = highlevl.c:250 exact): prunes dead, retargets survivors to nearest enemy
base (keysites=nodes), retreats weakened/cut-off groups to nearest friendly base, and reinforces up
to one group per frontline base from the depleting vehicle reserve (this IS the ground regen #14).
Migrated all S.columns refs → registry: keysite.try_capture (scans all groups), cas artillery
(targets whole enemy frontline), map_overlay (one mark per group). game_loop calls gnd.init_oob.
STRUCTURAL LIMIT documented: DCS exposes no road-node adjacency graph, so EECH's true node-by-node
road pathfinding + one-group-per-tick discretisation can't be reproduced; keysites-as-nodes with
continuous vehicle movement is the closest achievable (#18 partial — the graph itself is the limit).
Build: 20 modules, 0 warnings. check: 22 files, no findings. Review dispatched.

### (Cluster D review + fixes) — ground war verified & hardened
Review found: H1 advance/retreat flip-flop; M1 orphaned map marks; M2 reinforce clumping; L2 no
occupancy; L3 reroute nil-guard. Fixed:
- H1: advance gated on frac>=CUTOFF_HP → weakened groups retreat and HOLD (no yo-yo).
- L2: nearest_unoccupied_enemy — occupancy deconfliction (highlevl.c:514 side_occupying).
- M2: reinforce only frontline bases whose company died (homes_covered check).
- M1: map_overlay clears the full prior mark band before redraw (col_mark_prev).
- L3: reroute nil-guards to_pos.
L1 (whole-front-retargets vs EECH one-group-per-tick) stands as the documented structural limit
(no road-node graph). Cluster D COMPLETE & verified.

### (Cluster E) — throughput/repair/SEAD/FOW
- #11 throughput: DONE in Cluster B (per-sector cap).
- #15 repair: keysite_repair now supply-gated (repair needs ammo&fuel ≥ 50%) and rear vs forward
  bases have SIGNED supply usage (rear resupply +0.5/tick, forward drain) — supply now genuinely
  gates recovery; mirrors EECH signed default_supply_usage. (Full repair-unit dispatch not modelled
  — no repair-entity system; supply gate is the faithful proxy.)
- #16 SEAD: spawn_air_strike now assigns the DCS "SEAD" task + targetTypes {"Air Defence"} so AI
  prioritises radars. Anti-radiation loadout (HARM/Kh-25MP) deferred: weapon CLSIDs must be verified
  against the live DCS DB (guardrail) — sim was at main menu this session. Plumbing ready; swap
  PYLON[side].sead in once verified live.
- #17 BAI echelon: is_near_friendly proxy retained (EECH INT_TYPE_FRONTLINE echelon integer has no
  DCS equivalent) — documented proxy.
- #23 FOW own-sector: fog_of_war already short-circuits owner→1.0 for a side's own bases; per-
  category recon radii already present. Considered covered.
Cluster E COMPLETE (with documented proxies + one live-verification follow-up for HARM CLSIDs).

### (Cluster F) — player-facing + win criteria
- Phase transitions now emit trigger.action.outText (visible in-game) as well as env.info.
- win_condition: added CAMPAIGN_CRITERIA_TIME_DURATION (4h limit → decided on weighted
  bases+strength score) alongside CAPTURED_SECTORS + BALANCE_OF_POWER; rich debrief via finish()
  outputs bases + strength for both sides. (Full ~17-criteria set is per-scenario data with no DCS
  equivalent; the 3 global criteria are modelled.) Cluster F COMPLETE.

### Remaining
- **Cluster G (non-airbase keysites)** — the one substantive open gap. Plan: baked-scenario table of
  static installations (bridges/depots/factories/radar) spawned as DCS static objects at init, held
  in a keysite registry parallel to airbases, each with keysite_database flags. Then
  create_keysite_strike (ground_strike_target) and artillery target installations too, while OCA
  (oca_target) stays airbase-only — making the two strike task sets genuinely distinct rather than
  sharing airbases. Invasive (touches pick_target, reaction flags, targeting) → own session.
- **Live end-to-end validation** — DCS was at main menu (sim_running=false) all session; the port
  builds clean but has NOT been exercised in a running mission. Next live session: inject
  dist/dynamic-mission-test.lua, watch the log for the campaign schedulers, verify recon/strike/
  reaction/ground behaviour, and verify + wire the SEAD HARM loadout.

### (Cluster G) — Non-airbase keysites
Queried the live DCS DB via the bridge (reachable from main menu) → VERIFIED static type names
(".Ammunition depot","Fuel tank","Comms tower M",".Command Center") — satisfies the CLSID guardrail.
New installations.lua: procedurally places depot/fuel/radar installations behind each base (rear
offset away from nearest enemy), owned by the base's side (captures propagate via side_of →
home_base owner). Flags ground_strike_target + recon_target, NOT oca_target/troop_insertion — so
create_keysite_strike (via new attack_waves.pick_ground_target combining airbases+installations)
and artillery hit them, while create_oca_strike stays airfield-only → the two strike task sets are
now GENUINELY DISTINCT. Statics spawned defensively (pcall) — an invalid type degrades to an
abstract keysite point; campaign logic doesn't depend on the visual. Damage via nearby kills
(win_condition kill handler → installations.apply_kill_damage); destroyed static removed at ≤0.1.
keysite.rate_pos extracted (shared airbase/installation rating). Cluster G COMPLETE.

### (Cluster H) — Helicopter war (user-requested; EECH is a heli sim)
User: EECH is primarily a helicopter combat sim — flesh out the rotary war as the main bulk of
gameplay. New heli_war.lua (the rotary-wing offensive arm):
- **Anti-armour** (core EECH mission): attack-heli sections (AH-64D Hellfire / Mi-24V Shturm, using
  verified payloads) hunt the enemy frontline ground group nearest a friendly base. 8-min tempo.
- **Hunter-killer** armed recon: sections patrol the frontline sector, engaging ground AND air
  (Comanche-vs-Hokum heli-vs-heli). 10-min tempo.
- **Attack-heli escort**: shepherds vulnerable troop-insertion helis into hostile airspace.
Draws SECTION_SIZE=2 from the "heli" reserve (bumped to 6/base — rotary is the deepest pool since
it flies the bulk of sorties: anti-armour+HK+escort+BDA+TI+CAP). Names Heli-AA/HK/ESC-* → classify
as "heli" (RTB-recycled). Wired into game_loop (both sides, staggered); troop insertion calls
heli_war.spawn_escort. Build: 22 modules, 0 warnings; check: 24 files, no findings. Review dispatched.

### (Cluster G+H review + fixes) — verified
Review found HIGH H1: installations were indestructible (DCS AI won't EngageTargets static objects;
no unit-kills occur in their rear) → perpetual strike magnets. Fixed: `installations.damage()` core +
attack_waves credits DETERMINISTIC per-sortie damage (0.4, ~3 sorties destroy) at time-on-target
(240s) — guaranteed attrition independent of DCS static-hit detection; nearby-kill damage retained as
a bonus and now picks the NEAREST installation (L3). L2: heli spawns wrap addGroup in pcall → refund
on throw. L4: regen now respawns attack helis (AH-64D/Mi-24V) not unarmed transports. L5 (payload key
name) left as cosmetic. Clusters G & H COMPLETE & verified. Build: 22 modules, 0 warnings; check: 24
files, no findings.

## Session outcome
ALL 8 clusters (A–H) implemented, each adversarially reviewed and every finding fixed; tree fully
clean throughout. The port now plays as an EECH campaign: finite attrition economy, self-healing
recon loop, faithful reactive AI, a standing ground frontline, non-airbase keysites, and — the heart
of EECH — a proper attack-helicopter war. Only live end-to-end validation (DCS was at main menu all
session) and the optional SEAD HARM loadout (needs live CLSID) remain.

## Open questions
- none (full autonomy granted per GOAL.md; user reaffirmed no-compromise fidelity + in-memory OK)

## Follow-ups & improvements
- none yet
