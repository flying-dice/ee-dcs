# GAP ANALYSIS — EECH → DCS port, full feature parity — 2026-07-09

Audit of **current** `Scripts/dynamic-mission-test/*.lua` (all 29 modules read in full) against the
214-feature spec catalog (`specs/00-INDEX.md` + 10 subsystem specs) and the EECH C source at
`E:\eech_source_code`. Spec port-status columns were IGNORED (stale); every verdict below is against
current code with current line numbers. EECH claims re-verified in the C where load-bearing.

**Verdicts**
- **FAITHFUL** — matches EECH, constant/formula cited in code, and actually wired at runtime.
- **PROXY** — documented faithful proxy for a DCS structural limit (acceptable per CLAUDE.md).
- **DIVERGED** — value/formula does not trace to EECH (tuned-by-feel / invented) — port line + correct EECH line given.
- **DISCONNECTED** — implemented but not invoked / no consumer at runtime.
- **MISSING** — not ported. `MISSING (n/a)` = DCS-native or dead in EECH — correct omission, no work item.

**Summary counts** (214 features):
| Verdict | Count |
|---|---|
| FAITHFUL | 52 |
| PROXY | 62 |
| DIVERGED | 17 |
| DISCONNECTED | 6 |
| MISSING (real gap) | 24 |
| MISSING (n/a — DCS-native or dead in EECH) | 53 |

The 17 DIVERGED + 6 DISCONNECTED + 24 real-MISSING items are triaged into fix clusters at the end.

---

## Spec 01 — Session lifecycle (SESSION F1–F20)

| F | Verdict | Note |
|---|---|---|
| F1 session entity | PROXY | `campaign_state.lua` singleton (`M.S`) stands in for SESSION; weather/wind/pop-bounds DCS-native. |
| F2 per-frame update list | PROXY | `timer.scheduleFunction` replaces the entity update list; structural. |
| F3 timed scheduler table | PROXY | All 12 generators + 4 imap + FOW registered with EECH **campaign** periods/offsets (verified against highlevl.c:246-285, see §C roster). Two divergences: (a) port registers each generator **per side** with an invented half-period/+30 s stagger (`game_loop.lua:236-306`) — EECH registers ONE function that loops both forces at one offset; per-side cadence still matches, acceptable, but undocumented as a proxy. (b) CAS offset 0→5 s (`game_loop.lua:267`) — documented DCS silent-drop constraint, fine. No `fmod` phase-alignment to elapsed time — moot until persistence exists. |
| F4 game time / day segments | PROXY | DCS mission time; day segment has zero campaign consumers in EECH — correct omission. **But** `campaign_state.lua:18-19` invents PHASE_MID/PHASE_LATE (15/35 min) driving wave escalation — no EECH counterpart (EECH has no phases). See DIVERGED entry in Cluster F. |
| F5 night-skip / clock accel | MISSING (n/a) | DCS owns time. |
| F6 frame time acceleration | MISSING (n/a) | |
| F7 MP session resync | MISSING (n/a) | DCS native. |
| F8 weather model | MISSING (n/a) | DCS native. |
| F9 wind model | MISSING (n/a) | |
| F10 lightning | MISSING (n/a) | |
| F11 gameflow state machine | PROXY | `main.lua` → `reset.nuke` → `game_loop.start()`. |
| F12 campaign creation & objectives | FAITHFUL | `keysite.designate_objectives` (`keysite.lua:261-307`): isolation rating + frand1, top 5 — setup.c:126-289 cited, wired, win check consumes it. |
| F13 completion & victory | DIVERGED (one criterion) | Criteria (a)(b)(c) faithful and event-driven (`win_condition.lua:139-154`, fc_msgs.c:144-311). **Criterion (d) "military collapse"** (`win_condition.lua:157-174`: enemy ≤25% bases AND strength < STRENGTH_SURVIVAL) is invented — EECH has exactly three end conditions and NO others. Also: EECH's campaign **keeps running** after completion (session_complete only gates new task generation, fc_msgs.c:163); the port sets `S.game_over` which self-cancels every scheduler — world freezes. Fix: Cluster E. |
| F14 script triggers/events | MISSING (n/a) | Mostly dead machinery in EECH (only CAMPAIGN_TRIGGER_NONE polled, parsgen.c:218-237). |
| F15 save game / autosave | MISSING | The single largest missing subsystem (goals/03 P1). No work in current code. |
| F16 restore | MISSING | Ditto. `pilots.init` is restore-safe; nothing else is. |
| F17 pack_session serialisation | MISSING | Persistence path is `dcs_studio.file/sqlite` per guardrails — unbuilt. |
| F18 campaign UI surface | PROXY | `map_overlay.lua` + `pilots.build_menus` (F-10 Campaign menu) + status log. |
| F19 realism/cheat flags | MISSING (n/a) | DCS options. |
| F20 teardown | PROXY | `reset.lua` nuke on re-inject (better than EECH needs). |

## Spec 02 — Force, reserves & win criteria (FORCE F1–F37)

| F | Verdict | Note |
|---|---|---|
| F1 force entity/defaults | PROXY | `S.strength/objectives/...` per side; `force_attitude` unported — **verified**: EECH parses it (parsgen.c:1474) but NO AI consumer exists anywhere, so omission is faithful. |
| F2 hardware categories | PROXY | 7 roles vs 8 categories; `supply.ROLE_CATEGORY` map (informational) documents the mapping. |
| F3 live census | FAITHFUL | `cs.count_current_hardware` / `recalc_strength` (`campaign_state.lua:231-272`), fc_updt.c:136-161 formula exact. |
| F4 reserve seeding | PROXY | `RESERVE_PER_BASE` (`supply.lua:73-81`) — EECH values are warzone DATA (parsgen.c:1397-1435, assignment :1426), no C constant exists to match; per-base ledger localisation is header-documented. Values remain designer-tunable — acceptable but keep flagged as scenario data, not EECH data. |
| F5 consume-on-spawn | FAITHFUL | `supply.consume_base` at board assignment (force.c:238-241 cited). |
| F6 recycle to reserve | PROXY | `make_land_handler` recycle-on-RTB — `replace_into_force_info` has ZERO callers in shipped EECH (verified spec 02); header documents this as design-intent reconstruction. Keep. |
| F7 regen reserve gate | FAITHFUL | `regen.spawn_regen` blocks on ledger ≤0 (`regen.lua:286-289`, rg_updt.c:285-297); vehicles gated too via `ground_forces.spawn_group` consume (`ground_forces.lua:120`). |
| F8 force_percentage | FAITHFUL | `recalc_strength` = this/total ×100 (fc_updt.c:148-154; dead code in EECH but attested formula, documented). |
| F9 criteria engine | MISSING (n/a) | Dead code in EECH (fc_updt.c:86-495 commented) — correctly not ported. |
| F10–F24 criteria set (15) | MISSING (n/a) | All dead code; correctly omitted. Old port's 3-criteria model was removed — confirmed gone from `win_condition.lua`. |
| F25 criteria count hooks | MISSING (n/a) | Dead. |
| F26 live objectives win | FAITHFUL | `holds_all_objectives` (`win_condition.lua:50-57`, fc_msgs.c:180-211). |
| F27 airbase-exhaustion win | FAITHFUL | `has_usable_airbase` (`win_condition.lua:62-69`, fc_msgs.c:222-249; usable = eff ≥ 0.3, valid since every port keysite is air-capable). |
| F28 gunship-exhaustion win | PROXY | `has_combat_heli_capability` counts live + reserve + regen queue (`win_condition.lua:102-111`) — documented proxy for EECH's live air-registry census (port has no standing parked fleet). |
| F29 event-driven triggers | FAITHFUL | check_win from kill handler, do_capture, plus a 60 s admin poll (additive, harmless). |
| F30 campaign_completed handling | PROXY | outText + log; **see F13 divergence** — port halts the world, EECH does not. |
| F31 objective selection | FAITHFUL | = SESSION-F12. |
| F32 sector side count | PROXY | Base-ownership counts in status/win (no sector grid). |
| F33 kills/losses per-side stats | MISSING | No per-side kill/loss ledger (only per-player in pilots). Low impact (EECH consumer is stats UI). |
| F34 group_count registry | MISSING (n/a) | UI-only in EECH. |
| F35 task-gen stats & valid gate | PROXY | `S.board_failed` counts EXPIRE failures (`task_board.lua:305-309`); created/completed counters and the per-type valid gate absent (valid gate is warzone data; port task mix is code-defined — acceptable). |
| F36 replication | MISSING (n/a) | DCS native. |
| F37 force update cadence | MISSING (n/a) | Live no-op in EECH. |

## Spec 03 — Keysites & supply (KEYSITE F1–F19)

| F | Verdict | Note |
|---|---|---|
| F1 type database | PROXY | Partial reconstruction: `reaction.keysite_flags` (airbase row corrected: requires_cap=T, requires_barcap=F, ks_dbase.c:120-121 cited), `installations.FLAGS/PRODUCER` (factory +1.0 ammo, refinery +1.0 fuel — ks_dbase rows cited). The 9×28 table is not fully represented (no anchorage/radio rows) — acceptable for airbase+installation set. |
| F2 creation defaults | PROXY | Zone-authored registry (colour=side, name=type) replaces warzone attributes; register-don't-spawn honoured. |
| F3 strength/efficiency | FAITHFUL | eff = strength/max = base_health; supply excluded (ks_float.c:260-275 cited; `keysite_repair.lua:187-189`). |
| F4 update cadence | FAITHFUL | 60 s supply/repair tick (KEYSITE_UPDATE_SLEEP_TIMER) + 180 s board assign (KEYSITE_TASK_ASSIGN_TIMER). Missing minor: ×2 assign interval when keysite not USABLE (ks_updt.c:118-123) — slot/ledger gating substitutes; note only. |
| F5 supply tick | DIVERGED (small) | Airbase −0.2/−0.4, floor 10, cap 100 exact (`keysite_repair.lua:54-55,118-121`). **But every base drains at airbase rates including FARPs** — EECH FARP row is −0.05 ammo / −0.03 fuel (ks_dbase.c:232-271, spec 03 §2.3). Fix: branch on `S.base_kind` in `keysite_repair.tick`. Cluster G. |
| F6 crates & request threshold | PROXY | Abstract crate accumulator (`supply.credit_production/deliver_crate`); threshold 75 exact (en_suply.h:87), request-only-if-consumer ✓, CRATE_SIZE 10 ✓ (cargo.h:89,91). No physical crates — documented. |
| F7 supply-task distribution | PROXY | Instant crate delivery from side accumulator (`keysite_repair.lua:135-153`); no closest-producer selection, no interceptable supply flight. Producer death → no crates ✓ (the economic-vulnerability loop is live). Documented synthesis in `supply.lua` header. |
| F8 pick-up/drop-off accounting | PROXY | deliver_crate −10 / restock-to-100 exact (ks_msgs.c:230,238 cited). |
| F9 rearm/refuel time scaling | PROXY | Exact formula (en_suply.c:107, factor 5) applied to regen turnaround (`regen.lua:50-54,374-380`) — documented mapping onto the port's only rearm surface. |
| F10 repair system | DIVERGED (documented, partially) | Rate: 1%/min ≈ 1 building(0.1)/10 min for ~10 buildings — anchored to keysite.c:1628, acceptable. Inventions: (a) `REPAIR_MIN_SUPPLY = 50` ammo&fuel gate (`keysite_repair.lua:56,169-176`) — EECH repair has **no supply gate** (repair = repair-task delivery + timer only, ks_updt.c:169-222); (b) `STRIKE_SUPPRESS_TIME = 480` (`keysite_repair.lua:66`) — no EECH counterpart (EECH's equivalent brake is that a keysite below min eff is UNUSABLE and repair proceeds 1 building/10 min regardless). Both are load-bearing for the capture loop; keep only if re-documented as proxies for the repair-task delivery delay, else remove. Cluster G. |
| F11 below-min transitions | PROXY | UNUSABLE line 0.3 used for capture/win ✓; port adds `HEALTH_NEUTRALISED = 0.35` as launch/regen floor (`campaign_state.lua:27`) — documented buffer, but regen/launch blocked at 0.35 vs EECH 0.3 is a small undocumented-in-EECH divergence. Note only. |
| F12 capture trigger & probability | Split | **capture_roll FAITHFUL** — d = (eff−0.3)/0.7 × members/(members+losses), capture iff d < frand (mb_msgs.c:2287-2308 exact, `keysite.lua:666-678`). **Trigger DIVERGED** — see 04-F8/troop below (capture-on-dispatch). |
| F13 capture side effects | PROXY | Flip + size-aware repair bump (CAPTURE_REPAIR_SMALL 1.0 / LARGE 0.4, `keysite.lua:649-650` — documented proxy for the 5-building loop, keysite.c:1451-1462; reasonable: 5 buildings ≈ all of a FARP, partial for an airbase) + regen +6/+4 exact (keysite.c:1490/1494) + queue reseed + ledger zero + frontline recompute + win recheck. Composition of reseeded groups is generic heli/striker vs EECH's 2×attack/2×recon-attack/2×assault + 2×CAS/2×multirole — minor, note. |
| F14 kill/destroy side effects | PROXY | Ledger zeroing on capture = documented proxy for landed-aircraft destruction; **missing**: emergency transfer of inbound flights, task termination on keysite loss (in-flight sorties keep attacking a base that changed hands). Low-frequency; note for Cluster I. |
| F15 task assign / under-attack CAP | PROXY | Board assign ✓; defender CAP fires on attacker BIRTH (reaction) which covers the omniscient-defender path; EECH's *second* path — `notify_keysite_structure_under_attack` CAP (priority 10, 15 min, assist_timer 60±20 s, keysite.c:854-939) when bombs actually fall — is MISSING. Note for Cluster I. |
| F16 FARP enable by sector | MISSING | FARPs owned/active from OOB; no dormant-FARP activation as the front moves. Low impact on authored theatres. |
| F17 objectives/victory | FAITHFUL | = FORCE-F26..F29. |
| F18 WUT data override | PROXY | ME trigger zones are the authoring layer (colour=side, first-word=type) — the port's warzone-data analog. |
| F19 dead/debug supply code | MISSING (n/a) | Dead in EECH. |

## Spec 04 — Task generation (TASKGEN F1–F17)

| F | Verdict | Note |
|---|---|---|
| F1 scheduler | FAITHFUL | Campaign periods/offsets all match highlevl.c:246-268 (verified module by module: CAS 900/0(→5), SEAD 720/180, adv 720/12, arty 900/45, KS strike 450/15, patrol 300/5, FW xfer 900/150, TI 120/60, BAI 1200/300, HC xfer 450/120, sweep 1800/90, OCA 1800/390). Skirmish schedule absent (documented). Startup roster dump guards the offset≤0 class (`game_loop.lua:323-330`). |
| F2 advance/retreat | PROXY + DIVERGED constants | Standing frontline groups, 12-min tick ✓. Structural limit (no road graph) header-documented in `ground_forces.lua`. Divergences with no EECH source: `FRONT_DIST = 140000` (`ground_forces.lua:30`), `CUTOFF_HP = 0.5` retreat threshold (`:31`), reinforce-one-per-frontline-base (`:271-284`), and moving EVERY group each tick — EECH moves **one group one road node per force per tick**, destination rated `2.0 × IMAP_BASE_DISTANCE[enemy]` (highlevl.c:505-563). A closer proxy: per tick advance only the single best-rated group toward the highest-rated adjacent (Gabriel-neighbour) base. Cluster F. |
| F3 BAI | DIVERGED→DISCONNECTED in practice | Formula/caps/FOW>0.5-strict/fork all faithful (`cas_bai_sead.lua:492-528`). **But the echelon split is broken**: CAS keeps targets with `is_near_friendly(pos)` ≤ `frontl.FRONTLINE_RADIUS = 200 km` (`cas_bai_sead.lua:179-192`, `frontline.lua:44`) and BAI takes the complement. On a ~260 km theatre virtually every enemy group is within 200 km of a friendly base → **BAI's rated list is ~always empty; the BAI generator, its FOW fork and its recon stream never run**; CAS absorbs everything. 200 km traces to nothing in EECH (EECH: `INT_TYPE_FRONTLINE == 1` vs `> 1`, highlevl.c:877/:637). Fix: derive echelon from the (already-computed, currently unread) Gabriel frontline flags. Cluster B. |
| F4 CAS | FAITHFUL | Formula (1/3/2, max 6), no FOW gate, count 2, sector cap 1 (`cas_bai_sead.lua:432-467`); heli builder for CAS/BAI is the documented EECH heli-eligibility realignment (ts_dbase.c:511/:329). Subject to the same echelon caveat as F3 (CAS gets second-line targets too). |
| F5 keysite strike | DIVERGED (multiple) | Cadence 450/15 and COUNT 3 ✓. Everything else drifted: (1) **scoring formula wrong** — `keysite.rate_pos` (`keysite.lua:467-506`) computes `2·(1−air_def) + 3·proximity + 2·sector + obj_boost` and cites "highlevl.c:658-670" (that's the **BAI** block). EECH create_keysite_strike_tasks (verified highlevl.c:1109-1127) is `1·(1−IMAP_AIR_DEFENCE) + 4·IMAP_BASE_DISTANCE + 2·(1−efficiency) + 2·side_ratio`, max 9.0 — the port drops the efficiency term, halves the reach weight, doubles the airdef weight, and hand-rolls proximity/sector instead of using its own imap layers. (2) `obj_boost = 4·proximity` for objectives (`keysite.lua:504`) — invented (EECH importance term is commented out). (3) No `MIN_TASK_CREATION_RATIO 0.75` gate in `pick_targets` (`keysite.lua:552-570`). (4) No recon-first fork — EECH: `recon_target OR FOW<0.25 → RECON`, strike comes later via the reaction chain (highlevl.c:1179-1205); port strikes directly regardless of FOW. (5) No eff ≥ min gate (highlevl.c:1224: EECH does not ground-strike an already-suppressed keysite — TI takes over). (6) No dedup guard against an existing ground_strike/TI on the target (highlevl.c:1224-1231) — the 7.5-min cycle can double-task a base (`attack_waves.lua:374-398`). (7) Airbase/installation interleave (`attack_waves.lua:380-397`) + `installations.strike_targets_ranked`'s STRIKE_VALUE table and "finish-it-off" `(1−health)·2` bonus (`installations.lua:619-654`) are invented scoring — EECH scans the whole ground_strike set with the ONE formula above. (8) Survival-mode skip (`attack_waves.lua:362-368`) — no EECH counterpart (see Cluster E). Deterministic `strike_damage` at time-on-target remains an acceptable documented structural proxy (DCS empty airfields). Cluster A. |
| F6 OCA strike | DIVERGED | Cadence 1800/390 and count 1 ✓; but no FOW ≥ 0.25 gate (highlevl.c:1433), no dedup vs existing OCA_STRIKE/BDA/TI (highlevl.c:1435-1440), and shares the wrong `rate_pos` formula (EECH OCA: 1/4/2, max 7, highlevl.c:1370-1381). Cluster A. |
| F7 OCA sweep | FAITHFUL | Formula 1/4/2 exact, FOW ≥ 0.25 fork, count 2 (`cas_bai_sead.lua:709-741`). |
| F8 troop insertion | FAITHFUL (gen) / DIVERGED (payoff) | Generator: formula exact (1/3/3/2 max 9), FOW 0.2 recon fork (the previously-empty else is fixed, `troop.lua:352-369`), count 2, ratio 0.75, dedup ✓. Divergences: (a) **capture-on-DISPATCH** — `build_troop_insert` opens the capture window at spawn + CAPTURE_DELAY 150 s (`troop.lua:266-286`); EECH captures when the troops physically reach the TROOP_CAPTURE waypoint at the keysite (mb_msgs.c:2260-2325). The in-file rationale ("~150 km crossings took ~30 min") is a tuning argument, not a source citation; with FARP-staged transports the flight is short — restore arrival-triggered capture using the existing `check_landing_helis` proximity path and pass real survivor count + losses into `capture_roll`. (b) Defender **backup insertion missing from the periodic generator** (highlevl.c:1876-1897) — port has it only in the reaction path. (c) Survival-mode gate (`troop.lua:334-337`) invented. (d) `pending_captures` is module-local — lost on re-inject (put on `S`). Cluster C. |
| F9 SEAD | FAITHFUL | Formula 4/3 max 7, FOW 0.25 fork, count 2, sector cap ✓ (`cas_bai_sead.lua:550-583`). Target filter is attribute-AA (documented proxy for air_attack==10); minor: EECH excludes frontline AA (`!frontline_flag`, highlevl.c:1977-1981) — port includes them; fold into Cluster B echelon work. |
| F10 FW transfer | PROXY | Formula `4·bdist + 4·(1−min(idle,4)/4)` exact, top↔bottom pairing, `min(count/2, 3)` ✓ (`transfer.lua:98-170`); instant ledger move is the documented no-flight proxy. |
| F11 HC transfer | PROXY | Same, 450/120 ✓. |
| F12 SEAD ring helper | FAITHFUL (minor gap) | 4 km, max 3, abort >1 in reaction (`reaction.lua:295-325`). Missing the per-group FOW > 0.25 gate (highlevl.c:2653) — port SEADs fogged SAMs it shouldn't know about. Cluster I. |
| F13 troop patrol | FAITHFUL | 300/5, 1 per keysite, 4-man, 300+rand·50 m ✓ (`troop.lua:435-534`). |
| F14 artillery strike | PROXY code / **DISCONNECTED in practice** | Cadence/cap/FireAtPoint-1 km faithful-ish; `ARTY_DEFAULT_RANGE = 20 km` flat proxy (EECH per-group max weapon range); FOW check reads any enemy base within 200 km (`cas_bai_sead.lua:849-866`) vs EECH target-sector FOW; EECH also requires keysite targets eff ≥ min and not already tasked (highlevl.c:2937-3024). **The killer: the campaign never spawns artillery.** `GndCol` (tank/IFV/scout), `base_defenses` (SAM/AAA), and `installations` templates (garrison/AAA/SAM/EWR) contain zero Artillery-attribute units, so `run_artillery` finds 0 shooter groups and early-returns forever on any auto/empty mission (`cas_bai_sead.lua:776-796`). EECH fields SELF_PROPELLED_ARTILLERY/MLRS groups (M109A2/2S19, BM21) at artillery road nodes, ~5 vehicles each (faction.c:1640-1650). Fix with OOB composition, Cluster F. Counter-battery reaction also missing (REACT-F13, Cluster I). |
| F15 create_task engine | FAITHFUL | `task_board.lua`: UNASSIGNED records, per-type expiry table matches taskgen.c exactly (40/30/30/20/20/30/10/30/45 min), priorities match ts_dbase (9/6/7/6/4/9/7/9/10), critical ×2 sort (assign.c:201-204), expire→FAILED (ts_updt.c:99-124), refund discipline. Minor: EECH marks every reaction-created task critical=TRUE; port's CRITICAL set is {oca_strike, oca_sweep, troop_insertion} only — reaction wrappers pass no critical override. Note only. |
| F16 suitable.c matrix | PROXY | Single-role SUIT (EECH data reduces to 1.0/0.0 anyway); lowest-positive winner reproduced (`task_board.lua:197-229`). |
| F17 order.c OOB | PROXY | `ground_forces.init_oob` seeds standing groups; divisions unported (naming-only in EECH — acceptable). Composition divergence handled at 08-F1. |

## Spec 05 — Reactions (REACT F1–F14)

| F | Verdict | Note |
|---|---|---|
| F1 trigger path | PROXY | BIRTH = assigned, LAND = completed-success, death = failure (documented; H1 fix intact, `reaction.lua:509-591`). |
| F2 CAP reaction | FAITHFUL | requires_cap, dedup, 1800 s expiry+recycle, escort consumed at the defended base (`reaction.lua:167-209`). |
| F3 BARCAP reaction | FAITHFUL (dormant by data) | 6 km toward-attacker offset exact (`reaction.lua:211-255`); requires_barcap=false for airbases per ks_dbase.c:121 — never fires, exactly as EECH with no carriers. |
| F4 SEAD ring gate | FAITHFUL | Abort-if->1 (`reaction.lua:341-344`); FOW gate gap noted at 04-F12. |
| F5 TI at weak keysite | FAITHFUL | eff < min strict, dedup, targeted (`reaction.lua:364-368`). |
| F6 backup defender TI | PROXY | Fires with dedup on defender TI only (`reaction.lua:369-374`); EECH's 4-condition gate incl. <2 patrols (reaction.c:430-434) simplified. Low impact. |
| F7 OCA strike+sweep follow-on | DIVERGED (detail) | Both created, deduped ✓. But `run_oca_sweep(side)` re-runs the WHOLE generator scan (`cas_bai_sead.lua:745-750`) instead of creating an OCA_SWEEP **on the recon'd objective** (reaction.c:469-471) — the follow-on sweep can go to a different base and double-charges the 2-task generator budget. Give `run_oca_sweep` a target override like `run_oca_strike` has. Cluster I. |
| F8 ground-strike follow-on | FAITHFUL | eff ≥ min, no dedup — matches EECH's deliberate no-dedup (reaction.c:482-495). |
| F9 anti-ship strike | MISSING (n/a) | No ship keysites in the port theatre. |
| F10 group-objective SEAD/BAI | FAITHFUL | `react_recon_complete_group` both branches (`reaction.lua:396-413`). |
| F11 strike→BDA→re-strike | DIVERGED (detail) | Branch and BDA dedup faithful; but port **adds** a dedup on the re-strike (`reaction.lua:421`) where EECH deliberately has none (reaction.c:659-674 creates unconditionally, spec 05 open-Q5). This throttles the EECH strike-pressure loop. Remove the `has_task_against("ground_strike", …)` guard in `react_strike_complete` (the board's dedup marker makes it bite). Cluster I. |
| F12 task-failed handling | FAITHFUL | Death → no follow-on + registry clear; unassigned expiry → FAILED. |
| F13 artillery-fire reaction | MISSING | Counter-battery BAI/RECON vs firing battery, rating `(1−AIRDEF) + SURFACE_DEFENCE + 2·BASE_DISTANCE`, FOW>0.5 branch (reaction.c:703-810). This is also the ONLY consumer of IMAP_SURFACE_DEFENCE — porting it re-connects that layer. Cluster F/H. |
| F14 map-click (Campaign Commander) | MISSING (n/a) | Mod feature. |

## Spec 06 — Sectors, FOW, imaps, frontline (SECTOR F1–F19)

| F | Verdict | Note |
|---|---|---|
| F1 sector grid | MISSING (n/a → PROXY) | Bases-as-sectors documented throughout; structural. |
| F2 membership/tallest/task lists | PROXY | Per-sector task caps via nearest-base key in `apply_fork` (`cas_bai_sead.lua:219-247`). |
| F3 static painted sides | PROXY | Zone colours = the paint layer; x-median fallback documented. |
| F4 dynamic sector_side | PROXY | `sector_ratio` = friendly base fraction within 200 km (`cas_bai_sead.lua:125-144`) vs EECH keysite 1/d² influence — coarse but same direction; note the 200 km constant is shared with the broken echelon band (Cluster B) — decouple. |
| F5 sector side count | PROXY | Base counts in status/win. |
| F6 FOW grant | PROXY | Per-base; per-unit-type radius ×2, linear falloff (sector.c:434 cited); scan-based 30 s tick instead of movement-event grants — equivalent at this cadence. |
| F7 FOW decay & read | FAITHFUL | 30 s / −30, max 14400, own-side full-visibility override (`fog_of_war.lua:26-28,105-112`, sector.c:519-522). |
| F8 recon radii | FAITHFUL (values) / PROXY (mapping) | Radii table cites ac_dbase/vh_dbase per line (`fog_of_war.lua:41-56`); DCS attribute→type resolution is the documented proxy. Known-issue 9 → resolved. |
| F9 FOW thresholds | FAITHFUL | 0.5-strict BAI, 0.25 SEAD/OCA/arty, 0.20 TI (`cas_bai_sead.lua:78-81`, `troop.lua:52`). |
| F10 IMAP_IMPORTANCE | PROXY (dormant, matches EECH) | Invented health-based fill (`imap.lua:239-270`) but ZERO consumers in port — which matches EECH, where every importance term is commented out. No action; do not wire consumers. |
| F11 IMAP_BASE_DISTANCE | PROXY | Inverse-square within flat 150 km (`imap.lua:36,98-130`) vs EECH quadratic within per-type air_coverage_radius (airbase 400 km / FARP 100 km, ks_dbase). Max-combine ✓. Consider per-kind radii when touching Cluster A (the 4× weight makes this layer decisive). |
| F12 IMAP_AIR_DEFENCE | PROXY | Attribute-AA accumulation, 25 km×10 proxy scan range, += accumulation ✓ (`imap.lua:137-183`); periodic rebuild vs event-driven — fine. |
| F13 IMAP_SURFACE_DEFENCE | DISCONNECTED | Computed every 120 s (`imap.lua:190-232`) with **zero consumers** — its only EECH consumer is the unported artillery-fire reaction (REACT-F13). Wire via Cluster F/H or stop computing. |
| F14 normalisation/stagger | FAITHFUL | min-max, skip-if-flat, 120 s at 20/40/60/80 (`imap.lua:77-91,318-350`). |
| F15 imap weights in scoring | Split | FAITHFUL for CAS/BAI/SEAD/sweep/TI/transfer; DIVERGED for keysite strike + OCA strike (rate_pos does not read imaps at all — see 04-F5/F6). |
| F16 frontline algorithm | PROXY | Gabriel adjacency, computed at load + on capture only (no timer) — well-documented realignment. **But see connectivity: `is_frontline` has zero consumers** — the flags feed nothing but the pilot brief. EECH's frontline output is also unconsumed, so this is coincidentally faithful; Cluster B gives it a real consumer (echelon split). |
| F17 frontline placement | PROXY | init_oob per frontline base; composition divergence at 08-F1. |
| F18 road routing | MISSING (n/a) | Structural; documented in ground_forces header. |
| F19 exposure | MISSING (n/a) | Dead in EECH. |

## Spec 07 — Task engine & routing (TASK F1–F26)

| F | Verdict | Note |
|---|---|---|
| F1 create_task | PROXY | Board records with builder closures. |
| F2 states/lists | PROXY | UNASSIGNED/ASSIGNED/FAILED; COMPLETED handled by group lifecycle. |
| F3 timers/expiry | FAITHFUL | Unassigned expiry per type ✓; CAP stop-timer analog (1800 s despawn) ✓. |
| F4/F5 completed/terminated messaging | PROXY | RTB=success / death=failure event mapping. |
| F6 completion assessment | MISSING | No 0..1 rating / partial thresholds (e.g. ground strike success = eff dropped below 0.8×min, task.c:347-430). Port's deterministic strike_damage makes success unconditional — acceptable while damage is deterministic; revisit if damage becomes outcome-based. |
| F7 points award | PROXY | pilots.KILL_POINTS category proxy (documented); task score absent. |
| F8 per-creator expiry/skeletons | FAITHFUL (expiry) / PROXY (routes) | Values verified 1:1 (see 04-F15). |
| F9 3-min assign cadence | FAITHFUL | `ASSIGN_CADENCE = 180` (keysite.h:69 cited); one global pass (documented proxy for per-keysite staggered timers). |
| F10 sort/player-reserve/budget | DIVERGED (missing piece) | Priority sort + critical ×2 ✓. **Player task reservation MISSING**: EECH skips up to `reserve_task_count` (=2 airbase) fresh non-critical tasks per pass so humans can take them (assign.c:244-255) — this is the core "players are first-class in the tasking loop" mechanic for goal 03. Per-keysite assign budget (3/pass, assign.c:218) replaced by slot capacity — acceptable, but the reservation must come with player mission assignment (Cluster J). |
| F11 group search chain | PROXY | Ledger stock + slot + range replaces the 11-filter chain; `minimum_idle_count` reserve (assign.c:465-474) unrepresented — note. |
| F12 suitability | PROXY | See 04-F16. |
| F13 task-specific checks | MISSING | Escort speed-class match, TI-vs-airbase ≥2 members (assign.c:306-395). Low impact. |
| F14 locality gate | DIVERGED | `MAX_ASSIGN_RANGE = 400000` flat (`task_board.lua:111-115`) — comment admits it was widened to kill a stalemate. EECH (verified group.c ~:245-315): reject iff `ETA = distance / member_cruise_speed > task expire_timer`. Faithful proxy: per-assignment range cap = `cruise_speed(role) × expiry(type)` — striker/40-min ground strike ≈ 528 km (so the 400 km "holdout fix" is actually EECH-legal for fixed-wing), recon/10-min ≈ 180 km, **heli CAS/20-min at 55 m/s ≈ 66 km** (the flat 400 km currently lets FARP helis take tasks they can never reach in time — EECH would reject them). Cluster D. |
| F15 escort at assignment | DIVERGED | WAVE phase table (0/1/2 escorts by invented phase, `attack_waves.lua:56-60`) vs EECH threat-based `escort_required_threshold` (assign.c:598-627: escort iff route difficulty ≥ threshold; thresholds ts_dbase: ground strike 3, SEAD 5, TI 3, anti-ship 3; critical escort at ≥6). Faithful proxy: count enemy AA/enemy-owned bases along the leg (difficulty = min(airdef_sectors>>1,5)+min(enemy_sectors>>1,5), task.c:890-907) and escort when ≥ threshold. Also EECH escorts TI and SEAD flights, not just strikes. Cluster F(A). |
| F16 guide stack | MISSING (n/a) | DCS AI. |
| F17 route difficulty | MISSING | Needed by F15; port with proxy above. |
| F18/F19 engage tasks & allocation | MISSING (n/a) | DCS native targeting. |
| F20/F21 biased routing | MISSING (n/a → structural) | Straight DCS waypoints; documented (spec index #13). Optional future: 1-2 valley/offset midpoints. |
| F22 waypoint semantics | PROXY | DCS actions stand in. |
| F23 landing slots | PROXY | Per-sortie inflight counters, capacity SMALL 4 / LARGE 8 labeled proxies (`keysite.lua:395-454`); CAP/BARCAP not hard-gated (documented). |
| F24 keysite origin scoring | PROXY | Nearest-first + stock + slot vs EECH idle-bias/range⁴/saturation score (task.c:1030-1278) — same spirit, documented enough. |
| F25 kill/loss per task | MISSING | Low impact (debrief consumer). |
| F26 heli troop/fuel prep | MISSING (n/a) | DCS default fuel. |

## Spec 08 — Groups, divisions, regen (GROUP F1–F16)

| F | Verdict | Note |
|---|---|---|
| F1 group type database | DIVERGED (composition) | Aircraft type picks are documented DCS-availability proxies (F-16C/Su-25T, AH-64D/Mi-24V). **Ground composition diverges**: `GndCol` = 1 tank + 2 IFV + 1 scout (`ground_forces.lua:33-48`) and `installations.GARRISON_UNITS` = same 4-mix (`installations.lua:260-263`) vs EECH PRIMARY/SECONDARY_FRONTLINE groups = **all tanks** (M1A2/T80U, gp_dbase.c:704-786), placed at 7±2 vehicles (`int(28/4 ± 2)`, faction.c:1540-1542), artillery groups 5 vehicles (M109A2/2S19 / M270/BM21, faction.c:1640-1650), AA groups M48A1 Chaparral/SA-13. The `order.c:361` citation on the garrison template is wrong — that line is armoured-company organisation (3 groups/company), not a per-keysite garrison; EECH keysite ground presence is infantry patrols + population-data firing points only. Fix composition + add artillery groups (unblocks 04-F14). Cluster F. |
| F2 group entity creation | MISSING (n/a) | Fresh spawns per task (board model documented). |
| F3 member management | MISSING (n/a) | |
| F4 modes/sleep/idle gating | PROXY | Ledger counts; minimum_idle_count reserve unrepresented (note at 07-F11). |
| F5 supplies & rearm sleep | PROXY | See 03-F9. |
| F6 amalgamation | MISSING (n/a) | No persistent idle groups. |
| F7 retaliation/assistance | MISSING (n/a) | DCS AI native. |
| F8 return to base | PROXY | recycle-on-RTB. |
| F9 death/disband/emergency transfer | PROXY | Slot release + regen enqueue on death ✓; no emergency transfer on base loss (note at 03-F14). |
| F10 callsigns | MISSING (n/a) | |
| F11 divisions | MISSING (n/a) | Naming-only in EECH. |
| F12 regen entity lifecycle | PROXY | 60 s tick documented as proxy for DATA-DRIVEN `regen_frequency[side]` (parsgen.c:1500-1522; values not in C tree — spec 08 open-Q1). |
| F13 regen FIFO queues | FAITHFUL | Ring size 5, overwrite-oldest with visibility (`regen.lua:146-157`, rg_updt.c:763-814); aircraft-only documented (ground regen = ground_forces reinforce; Insert/recon one-shots documented). |
| F14 regen gating & spawn | FAITHFUL / one gap | Usable gate + reserve gate + supply-scaled turnaround ✓. **Player-landed veto MISSING** (rg_updt.c:311-339: no regen at a keysite while a human sits landed there) — directly relevant to the "players are first-class" guardrail once players base at FARPs. Small fix: skip `spawn_regen` when a player unit is on the ground within ~2 km of the base. Cluster J. |
| F15 capture queue resize/seed | FAITHFUL | +6 heli/+4 FW, shrink on loss, reseed at captured base (`keysite.lua:656-705`, `regen.lua:166-180`; keysite.c:1266-1282, 1481-1517). |
| F16 category group lists | MISSING (n/a) | Dead in EECH. |

## Spec 09 — Warzone data & roads (WARZONE F1–F21)

| F | Verdict | Note |
|---|---|---|
| F1 master tag schema | PROXY | Zones (colour/side, name/type) are the authoring layer. |
| F2 CAMPAIGN_DATA | PROXY | Theatre scoping (zones or densest ~260 km cluster, matching EECH map extent, `keysite.lua:196-224`). |
| F3 faction declaration | PROXY | Two hardcoded sides. |
| F4 hardware reserves | PROXY | See 02-F4. |
| F5 task-gen config | MISSING | No per-type valid toggles (data-driven per warzone in EECH). Low. |
| F6 regen frequency | PROXY | See 08-F12. |
| F7 keysite/initial OOB | PROXY | Zones + register-don't-spawn + empty-zone templates (compositions → Cluster F). |
| F8 scripted tasks | MISSING (n/a) | |
| F9 frontline force placement | PROXY | init_oob (composition → Cluster F; artillery missing → Cluster F). |
| F10 criteria/trigger scripting | MISSING (n/a) | Dead / covered by win_condition. |
| F11 force tick | MISSING (n/a) | Dead in EECH. |
| F12 force bookkeeping | PROXY | Census + ledgers. |
| F13 sector-side PSD | PROXY | Zone colours. |
| F14 city/keysite templates | PROXY | `installations.TEMPLATES` — sensible authored fallback but compositions invented and the order.c:361 citation is wrong (see 08-F1); re-document as designer data, fix garrison composition in Cluster F. |
| F15 airfield/FARP/carrier placement | PROXY | DCS airbases + `farps.lua` forward network; FIXED_WING_PER_SIDE=2 is a proxy for popread's "handful of fixed-wing airbases" — documented. Carriers n/a. |
| F16 AAA/SAM placement | PROXY | `base_defenses` garrisons (auto path) — EECH SAM sites come from population data (FORMATION_COMPONENT_LIGHT_SAM_AAA_GROUP, popread.c:2200-2210); compositions are DCS-verified picks, acceptable as authored data; zone path is author-placed ✓. |
| F17 routegen | MISSING (n/a) | DCS native taxi/landing. |
| F18 road files | MISSING (n/a) | Structural. |
| F19 road queries/advance | MISSING (n/a) | Structural; proxied at 04-F2. |
| F20 briefing database | MISSING | `pilots.build_brief` is a small situational analog; per-task briefing/debrief text system unported. Low priority (UI). |
| F21 briefing generation | MISSING | Ditto. |

## Spec 10 — Pilots & multiplayer (PILOT F1–F25)

| F | Verdict | Note |
|---|---|---|
| F1 pilot entity | PROXY | `pilots.get_or_create` keyed by getPlayerName (`pilots.lua:108-129`). |
| F2 pilot destroy | MISSING (n/a) | DCS slots. |
| F3 server pilot from log | MISSING (n/a) | |
| F4 join/side selection | MISSING (n/a) | DCS slotting; join brief on BIRTH is the port's value-add. |
| F5 join/quit announce | MISSING (n/a) | DCS native; brief covers join. |
| F6 session kills/high-score | PROXY | Side roster via "My Record" (no top-10 table; EECH's own feed is commented out — spec 10 open-Q3). |
| F7 career log persistence | PROXY (dormant) | `S.pilots` in-memory, restore-safe init; disk persistence = goals/03 P1 (Cluster J). |
| F8 rank thresholds | FAITHFUL | 0/7500/32000/120000/250000, no demotion (`pilots.lua:53-59`, player.c:73-77). |
| F9 mission-termination awards | MISSING | Needs player task assignment (F19); header documents. |
| F10 valour medals | PROXY | Thresholds cited (play_md.c:218-260); cumulative-score stand-in documented. |
| F11 Air Medal | MISSING | Documented (needs debrief loop). |
| F12 aviator wings | MISSING | Documented incl. the ×1000-bug do-not-reproduce note. |
| F13 Purple Heart | MISSING | Documented. |
| F14 campaign medals | MISSING | Documented. |
| F15 kill classification/deaths | FAITHFUL | classify_victim mirrors player.c:912-977 categories via attributes; friendly-kill zero (`pilots.lua:134-148,197-200`). |
| F16 kill-credit pipeline | PROXY | Category KILL_POINTS documented proxy for per-entity POINTS_VALUE; threat bonuses omitted (documented). |
| F17 player-flyable filtering | PROXY | PLAYER_FLYABLE set for mission display (`pilots.lua:93-96`). |
| F18 planner locks & AI reserve for players | MISSING | **AI does not hold tasks back for humans** (assign.c:244-255) — with F19, the MP payoff spine. Cluster J (+ D). |
| F19 player task assignment | MISSING | Display-only "Request Mission"; blocked on P0 (player slots), documented. Cluster J. |
| F20 gunship possession | MISSING (n/a) | DCS native. |
| F21 MP claim protocol | MISSING (n/a) | |
| F22 join/state sync | MISSING (n/a) | |
| F23 disconnect handling | MISSING (n/a) | |
| F24 per-pilot difficulty | MISSING | Low priority. |
| F25 AI pilot names | MISSING (n/a) | Dead in EECH. |

---

# Section B — Connectivity audit (the "lazy port" hunt)

All findings verified by grep against current code; line numbers current as of this audit.

## B1. Module exports vs callers

**Dead exports (ZERO external callers) — delete or wire:**

| Export | Evidence | Disposition |
|---|---|---|
| `fog_of_war.grant` (`fog_of_war.lua:117`) | no caller anywhere | Dead since the per-unit scan does grants internally. Delete, or use it to grant FOW on recon time-on-target (would make the recon fork sharper than the incidental overflight scan). |
| `keysite.best_friendly_base` (`keysite.lua:314`) | no caller | Pre-task-board leftover. Delete. |
| `keysite.best_friendly_airbase` (`keysite.lua:340`) | no caller | Ditto (its atype/need "signature compatibility" args serve nobody). Delete. |
| `keysite.behind_base` (`keysite.lua:364`) | no caller | Pre-ground-spawn era (in-air spawn offsets). Delete. |
| `task_board.has_live_task_of_type_against` (`task_board.lua:342`) | no caller | Spec-facing alias of `cs.has_task_against`. Harmless; keep or delete. |
| `farps.is_heli_only` (`farps.lua:144`) | no caller | Heli-only enforcement lives in the ledger seeding (`supply.lua:135-146`); function is dead. Delete or use in regen/board as a belt-and-braces gate. |
| `frontline.is_frontline` (`frontline.lua:117`) | no caller | The entire Gabriel frontline_flag computation has ONE consumer: `pilots.build_brief` via `get_frontline` (display string). Matches EECH (whose frontline list is also unread) — but Cluster B gives it its first real consumer (CAS/BAI echelon). |
| `heli_war.schedule_anti_armour` / `schedule_hunter_killer` (`heli_war.lua:220,250`) + private `frontline_point`, `heli_sorties` | documented RETIRED in game_loop.lua:259-264 | Dead code including the invented strength-ratio `heli_sorties` sortie scaler. Delete the two schedulers and both helpers (module keeps `build_attack_heli`, `spawn_escort`). |
| `main.lua` legacy wave layer (`spawn_supply`, `spawn_heli_cap`, `spawn_ground_patrol`, `run_*_wave`, ~280 lines) | gated behind `_G.DMT_ENABLE_LEGACY_LAYER` (default off) | Documented retired; still shipped in the bundle. Delete (CLAUDE.md backlog P2). |

**Protected single-shot exports (never-replace list) — ALL verified to have live callers:**
`attack_waves.run_strike` (reaction.lua:390,424), `attack_waves.run_oca_strike` (reaction.lua:380),
`cas_bai_sead.run_oca_sweep` (reaction.lua:383), `cas_bai_sead.spawn_sead_against` (reaction.lua:312,400),
`cas_bai_sead.spawn_bai_against` (reaction.lua:408), `troop.run_troop_insertion` (reaction.lua:366,372),
`recon.spawn_recon` (cas_bai_sead.lua:241 apply_fork + troop.lua:363), `reaction.spawn_bda`
(reaction.lua:436, internal strike-complete path), `heli_war.spawn_escort` (troop.lua:288). Chain intact.

## B2. Scheduler roster — registration vs effect

30 timers total: 23 via `game_loop.start()` plus board/supply-status/repair/regen/fow/imap x4/overlay/
admin x2/scenery-poll/spawn-drain self-registrations. All offsets > 0 (CAS clamped >= 1 s,
`cas_bai_sead.lua:475`); the startup roster dump (`game_loop.lua:323-330`) guards the historical
offset<=0 silent-drop class. `frontline.schedule_update` is an intentional documented no-op.

**Schedulers that fire but whose body can never do work (the imap-had-no-consumer class):**

1. **Artillery (both sides)** — `run_artillery` requires own groups with the DCS `Artillery`
   attribute; the campaign spawns none (GndCol = tank/IFV/scout; base_defenses = SAM/AAA; templates =
   garrison/AAA/SAM/EWR). On any auto/empty mission the scheduler early-returns forever
   (`cas_bai_sead.lua:776-796`). EECH fields SP artillery/MLRS groups at OOB (faction.c:1640-1650).
   To Cluster F.
2. **BAI (both sides)** — second-line filter `not is_near_friendly(pos)` with a 200 km band means the
   rated list is empty on any scoped theatre; BAI, its FOW gate and its recon downgrades never
   execute (`cas_bai_sead.lua:512`). To Cluster B.
3. `game_over` halts every scheduler permanently (generation-guard pattern) — EECH keeps the world
   running after a win (see 01-F13). To Cluster E.

## B3. S.* state fields — writers vs readers

| Field | Writers | Readers | Status |
|---|---|---|---|
| `S.base_warehouse` | keysite.lua:101-107 (zone init) | none | **Write-only.** Registered airbase aircraft inventory feeds nothing (presumably meant to seed/scale the ledger). Either seed `RESERVE_PER_BASE` from it or drop the registration. |
| `S.force_current` | recalc_strength | none | Write-only diagnostic. Harmless; keep or drop. |
| `S.winner` | win_condition | none | Terminal flag; fine. |
| `S.base_ledger[*]["troop"]` | seeded (supply.lua:80,143), credited by convert_reserves | **never consumed** | Dead pool: no SUIT entry / spawner draws role "troop" (insertions draw "transport"). Crates converted into it are wasted (1 of 4 fuel-crate round-robin slots vanishes). Remove the role or route insertion troops through it. |
| imap SURFACE_DEFENCE layer | imap.lua updater | none | DISCONNECTED (see 06-F13); its only EECH consumer is the unported REACT-F13 counter-battery reaction. |
| imap IMPORTANCE layer | imap.lua updater | none | Dormant — faithful to EECH (all importance terms commented out). Leave. |
| `troop.pending_captures` | troop.lua (module-local) | troop.lua | Not on S — lost on re-inject; a capture window in flight silently vanishes. Move to `S.pending_captures`. |
| `S.base_idle_groups` | transfer.update_idle_groups | transfer.score_base | OK (self-contained). |
| Everything else (`base_health/owner/pos/kind/efficiency/last_strike`, `objectives`, `strength`, `ground_groups`, `base_inflight/group_launch_base`, `active_tasks`, `board_tasks/failed`, `production`, `fow`, `regen_queue`, `patrol_groups`, `pilots`, `keysites`, `spawn_queue`, `_recycled/_completed`) | — | — | Written AND read; verified. |

## B4. Event handlers — chain completeness

Registered via tracked `_G.__dmt_handlers` (reset-safe) + `__dmt_static_death_handler`:

- **S_EVENT_KILL** (win_condition): keysite.apply_kill_damage, check_win, pilots.on_kill,
  installations.apply_kill_damage. Complete. **Note:** kills-near-a-base reducing keysite building
  strength (`KILL_RADIUS 8 km / KILL_DMG 0.08`, campaign_state.lua:56-57) is itself an invented
  attrition channel — EECH keysite strength changes only when buildings die. With deterministic
  strike_damage now carrying the load, this channel double-dips (a contested base bleeds structure
  from every nearby air-to-air kill). Candidate for removal/re-scope in Cluster G.
- **S_EVENT_DEAD** (regen + reaction + static handler): slot release on whole-group death, regen
  enqueue, pilots.on_death, task-registry clear, registered-static keysite drain. Complete.
- **S_EVENT_LAND** (supply + reaction): slot release, role classify, recycle survivors to landing
  base, despawn +30 s; completion dispatch (strike follow-on / recon chain) with once-guard.
  Complete. classify_role/classify_group prefix tables verified in sync (supply.lua:101-118 vs
  regen.lua:86-103).
- **S_EVENT_BIRTH** (reaction): pilots.on_birth (join brief) + defender CAP scramble from the
  registered task. Registration precedes BIRTH even under the spawn queue (register_task runs at
  enqueue). Complete.

## B5. Stubs, empty branches, constant-instead-of-computed

- No `TODO` / `not implemented` markers remain in Scripts/ (grep clean).
- `frontline.schedule_update` — intentional documented no-op.
- `keysite.rate_pos(attacker, tpos, th, is_objective)` — **`th` parameter is dead** (the damage term
  was removed in the anti-concentration fix but the parameter and all call sites still thread it).
  Contract drift; clean up with Cluster A.
- `reaction.keysite_flags(_base)` ignores its argument — fine (airbase-only universe), self-documented.
- pcall-swallow scan: all pcall sites either log via `log_fn`/`cs.dbg` or are guarded degradations
  (missionCommands, getWarehouse). No silent swallow-without-log cases found.
- `attack_waves` installations path: EngageTargets cannot hit statics — deterministic
  `installations.damage` at time-on-target is the documented guaranteed path (not a stub).

## B6. Cross-module contract drift

- task_board builder contract (consume-primary-role-then-build, refund-on-nil/throw) honoured by all
  builders (strike package, air strike, oca sweep, recon, troop insert, attack heli, escort). Escort
  sub-consumption in build_strike_package is a secondary consume with its own refund, documented.
- `board.create_task(target.group)` (recon/SEAD) is carried but never read by try_assign — harmless.
- `supply.produce` = recycle alias kept for transfer call sites — documented.
- `cs.PHASE_*`/`current_phase` consumed only by attack_waves WAVE + pilots brief + status log — the
  whole phase system rides on one invented table (see Cluster F).

---

# Section C — EECH-side completeness sweep

Cross-check of `start_high_level_ai()` (highlevl.c:181-287, campaign branch) plus per-entity update
loops against the port's scheduler roster:

| EECH periodic job (campaign freq/offset s) | Port counterpart | Status |
|---|---|---|
| create_cas_tasks 900/0 | cas_bai_sead.schedule_cas 900/5,30 | OK |
| create_troop_patrol_tasks 300/5 | troop.schedule_patrol 300/5,35 | OK |
| create_advance_and_retreat_tasks 720/12 | ground_forces.schedule_ground 720/12 | OK (model diverges, 04-F2) |
| create_keysite_strike_tasks 450/15 | attack_waves.schedule_keysite_strikes 450/15 | OK (formula diverges, 04-F5) |
| create_artillery_strike_tasks 900/45 | cas_bai_sead.schedule_artillery 900/45 | registered, but NO shooters exist (B2.1) |
| create_troop_insertion_tasks 120/60 | troop.schedule_troop_insertion 120/60 | OK |
| create_oca_sweep_tasks 1800/90 | cas_bai_sead.schedule_oca_sweep 1800/90 | OK |
| create_helicopter_transfer_tasks 450/120 | transfer.schedule_hc_transfer 450/120 | OK |
| create_fixed_wing_transfer_tasks 900/150 | transfer.schedule_fw_transfer 900/150 | OK |
| create_sead_tasks 720/180 | cas_bai_sead.schedule_sead 720/180 | OK |
| create_bai_tasks 1200/300 | cas_bai_sead.schedule_bai 1200/300 | registered, but echelon filter starves it (B2.2) |
| create_oca_strike_tasks 1800/390 | attack_waves.schedule_oca_strikes 1800/390 | OK (gates missing, 04-F6) |
| normalise_*_imaps x4 120/20-80 | imap.schedule_update 120/20+20i | OK |
| update_client_server_sector_fog_of_war 30/8 | fog_of_war.schedule_decay 30/8 | OK |
| update_client_server_sector_side_count 60/15 | recalc_strength in 120 s status + event-driven | PROXY, fine |
| update_campaign_triggers 1/0 | none | n/a (dead-ish scripting layer) |
| keysite update: supply tick 60 s | keysite_repair 60 s | OK |
| keysite update: assign timer 180 s | task_board 180 s | OK |
| regen entity tick (data-driven freq) | regen 60 s | PROXY |
| force update 5 s criteria | dead in EECH | n/a |

**EECH campaign mechanics with NO port counterpart that the specs' rollup underplays or misses:**

1. **SP artillery in the ground OOB** (faction.c artillery-node placement) — not just "roads not
   ported": with zero artillery units the whole artillery generator AND the counter-battery reaction
   surface are unreachable (B2.1). Spec 04 lists F14 as ported-at-cadence; runtime says dead.
2. **Under-attack defensive CAP + assist timer** (keysite.c:854-939) — reaction covers the
   task-assigned CAP only; a base being bombed by a package whose task was never registered
   (a human player's strike!) never scrambles defence. Matters for MP.
3. **Emergency transfer / task termination on keysite loss** (keysite.c:945-1283) — in-flight sorties
   keep prosecuting a base after it flips; the parked ledger is zeroed but airborne tasks are not
   retargeted/terminated.
4. **Regen player-landed veto** (rg_updt.c:311-339) — EECH's regen expression of "players are
   first-class": no AI regen at a keysite while a human sits landed there.
5. **EECH continues after victory** (fc_msgs.c:163 gates only new task generation) — the port's
   `S.game_over` freezes every scheduler and handler chain.
6. **Player task reservation** (assign.c:235-255) — spec'd (07-F10 / PILOT-F18) but worth restating:
   this is the concrete mechanism that makes an MP campaign leave missions for humans.
7. **Skirmish schedule** (highlevl.c:220-242) — consciously omitted; fine for the MP-server goal.

---

# Prioritized fix list — implementation clusters

Ordered by gameplay impact (the user's complaint classes: "too fixed-wing", "captures too slow/odd",
"sites spread out", "mechanics not connected"). Each cluster = one implementable unit touching the
same modules, with the EECH answer already researched above so no re-research is needed.

**Cluster A — Strike targeting fidelity** (`keysite.lua`, `attack_waves.lua`, `installations.lua`) — the biggest single divergence set.
Realign `rate_pos` to `1*(1-IMAP_AIR_DEFENCE[enemy]) + 4*IMAP_BASE_DISTANCE[own] + 2*(1-eff) + 2*side_ratio`
(highlevl.c:1109-1127, max 9.0) reading the EXISTING imap layers; delete obj_boost and the dead `th`
param; add MIN_TASK_CREATION_RATIO 0.75 to pick_targets; add per-target dedup (no live
ground_strike/TI, highlevl.c:1224-1231); add the recon-first fork (recon_target OR FOW<0.25 → recon;
the strike then arrives via the existing recon-complete reaction — plumbing already exists); add the
eff>=min gate; OCA strike: FOW>=0.25 gate + dedup + the 1/4/2 formula (highlevl.c:1370-1381,
:1433-1440); fold installations into the same rated scan (drop STRIKE_VALUE/finish-off bonus or
re-document as designer data). Impact: strike concentration/advance behaviour becomes EECH's and
three invented scoring systems disappear at once.

**Cluster B — Echelon/frontline wiring** (`cas_bai_sead.lua`, `frontline.lua`) — un-starves BAI.
Replace the 200 km `is_near_friendly` band with frontline-flag echelon: a target whose nearest
enemy-owned base is Gabriel-frontline is FRONTLINE==1 (CAS); anything else is second-line (BAI).
Gives `frontline.is_frontline` its first real consumer; exclude frontline AA from the SEAD scan
(highlevl.c:1977-1981); decouple SECTOR_RATIO_RADIUS from FRONTLINE_RADIUS. Impact: BAI and its
recon stream come alive; CAS stops absorbing the whole ground war; the rotary/fixed-wing mix moves
toward EECH's.

**Cluster C — Capture on arrival** (`troop.lua`) — the "captures feel wrong" fix.
Open the capture window from the `check_landing_helis` arrival-proximity path (already implemented!)
instead of at dispatch (mb_msgs.c:2260-2325: EECH captures at the TROOP_CAPTURE waypoint at the
keysite); pass the real survivor count and losses into capture_roll; move pending_captures onto S;
add the generator-side defender backup insertion (highlevl.c:1876-1897). With FARP-staged transports
the transit is short, removing the original motivation for dispatch-capture.

**Cluster D — Assignment locality & budget** (`task_board.lua`).
Replace flat MAX_ASSIGN_RANGE 400 km with the EECH ETA gate: max range = cruise_speed(role) *
EXPIRY(type) (group.c:245-315: reject iff distance/cruise > expire_timer). Role cruise speeds:
striker/escort/recon ~220-300 m/s, heli 55, transport 100. Result: heli tasks cap at ~66-150 km
(fixes FARP helis accepting unreachable tasks the EECH gate would reject) while fixed-wing ground
strike reaches ~528 km (legitimising the anti-stalemate reach the 400 km hack was for). Optionally
add the per-keysite assign budget of 3/pass (assign.c:218).

**Cluster E — Win/posture cleanup** (`win_condition.lua`, `campaign_state.lua`, all survival-gate call sites).
Delete criterion (d) military collapse (EECH has exactly three end conditions); delete the
STRENGTH_SURVIVAL gates in attack_waves/troop/ground_forces (verified: force_attitude is parsed but
NEVER consumed by EECH AI — there is no survival mode; the stall it patched is properly fixed by
Clusters A/C/D); STRENGTH_DEFEAT has no reader — delete. On game_over: stop task GENERATION but keep
the world/handlers alive (fc_msgs.c:163 semantics — EECH campaigns keep running after the banner).

**Cluster F — Force composition & escalation** (`ground_forces.lua`, `installations.lua`, `attack_waves.lua`, `cas_bai_sead.lua`, `campaign_state.lua`).
(1) Ground groups → EECH composition: primary-frontline all-tank groups of 7±2 (faction.c:1540-1542;
gp_dbase M1A2/T80U rows), and ADD SP-artillery groups (~5x M109A2 / 2S19, faction.c:1640-1650) to
the OOB — unblocks the artillery generator (B2.1). (2) Port REACT-F13 counter-battery (BAI/recon vs
the firing battery, rating (1-AIRDEF)+SURFACE_DEFENCE+2*BASE_DISTANCE max 4, FOW>0.5 branch,
reaction.c:703-810) — re-connects the SURFACE_DEFENCE imap layer. (3) Escorts: threat-threshold
model (assign.c:598-627 with the task.c:890-907 difficulty proxy — count enemy-AA/enemy-owned bases
along the leg, escort iff >= threshold 3 for strikes) replacing the WAVE phase table; retire
PHASE_MID/LATE or demote to logging. (4) Fix the order.c:361 miscitation on the garrison template
and mark template compositions as designer data.

**Cluster G — Keysite economy constants** (`keysite_repair.lua`, `campaign_state.lua`).
FARP drain -0.05/-0.03 by base_kind (ks_dbase.c FARP row); decide REPAIR_MIN_SUPPLY (EECH repair has
NO supply gate — remove, or re-document as the repair-task-delivery proxy) and STRIKE_SUPPRESS_TIME
(document as proxy or remove); reconsider the invented kill-proximity keysite damage channel
(KILL_RADIUS/KILL_DMG, campaign_state.lua:56-57) now that deterministic strike damage carries the
attrition load.

**Cluster H — Dead-code & disconnection sweep** (multiple modules, low risk).
Delete: fog_of_war.grant, keysite.best_friendly_base/airbase/behind_base, farps.is_heli_only,
heli_war retired schedulers + helpers, main.lua legacy layer, STRENGTH_DEFEAT. Resolve: the "troop"
ledger role (remove from ROLES/RESERVE_PER_BASE/FUEL_RESERVE_ROLES or give it a consumer) and
S.base_warehouse (seed the ledger from it or drop the registration).

**Cluster I — Reaction detail fidelity** (`reaction.lua`, `cas_bai_sead.lua`, `keysite.lua`).
Targeted OCA sweep on the recon'd objective (add a tname override to run_oca_sweep, reaction.c:469);
remove the invented re-strike dedup in react_strike_complete (EECH creates unconditionally,
reaction.c:659-674); add the FOW>0.25 gate to the SEAD ring (highlevl.c:2653); under-attack CAP path
(keysite.c:854-939, assist timer 60+-20 s) so unregistered/player attacks also scramble defence;
terminate/retarget airborne tasks on keysite capture (keysite.c:1248-1260).

**Cluster J — MP/pilot spine** (goal 03 proper; `task_board.lua`, `pilots.lua`, `regen.lua`, persistence).
Player task reservation (skip up to 2 fresh non-critical tasks per assign pass, assign.c:244-255);
player mission assignment (PILOT-F19, once player slots exist); regen player-landed veto
(rg_updt.c:311-339); persistence of S (including S.pilots and pending_captures) via the dcs_studio
bridge.

**Suggested order:** A → B → C → F → D → E → I → G → H → J. A/B/C attack the reported gameplay
symptoms directly; F restores the missing arms (artillery + counter-battery + escorts); D/E remove
the tuned crutches those fixes obsolete; I/G polish fidelity; H is safe cleanup any time; J rides
the goal-03 MP track.

---

# RESOLUTION ADDENDUM — 2026-07-09/10 session

ALL TEN CLUSTERS IMPLEMENTED, each adversarially reviewed (review findings fixed and re-gated).
See goals/03-mp-server-playout/2026-07-09-full-parity-gap-analysis.journal.md for the full record.
Every DIVERGED and DISCONNECTED item above is closed; the remaining open items are:
- **Persistence (SESSION-F15/16/17)** — still the largest missing subsystem (goal-03 P1; needs the
  dcs_studio bridge serialization design).
- **Player mission assignment (PILOT-F19)** — blocked on P0 player slots; reservation + veto + brief
  + menu are in place.
- **Watch-list from reviews (live-soak items):** recon pool depth (1/airbase now load-bearing for
  the recon-first strike spine); artillery DCS types M-109/MLRS/SAU Msta/Grad-URAL are
  UNVERIFIED-IN-LIVE-DB (run test/spawn_test.lua); post-victory world-continues semantics is a
  documented proxy (EECH literally never gates generation — widen if wanted).
- Low-priority spec gaps consciously deferred: FORCE-F33 per-side kill stats, KEYSITE-F16 dormant
  FARP activation, TASK-F6 completion assessment (moot while strike damage is deterministic),
  TASK-F13 escort speed-class match, WARZONE-F20/21 briefing text system, PILOT medals needing a
  debrief loop.
