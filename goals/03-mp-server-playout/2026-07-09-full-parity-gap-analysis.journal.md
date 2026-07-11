# Journal: MP-server playout — 2026-07-09 (full-parity gap analysis)

**Goal:** goals/03-mp-server-playout/GOAL.md
**Session focus:** User directive — full gap analysis of the port vs EECH C source (faithful /
partial / lazy-disconnected / missing), then drive to FULL feature parity with no "lazy" ports.
User reports repeated live-test findings of mechanics that exist in code but are not connected.

## Log
### Session open — orientation
Read GOAL.md + 2026-07-07 journal (repair/capture/targeting fixes, templates, logging pass) +
2026-07-06 spec-catalog + close-spec-gaps journals. Ground truth for the audit:
- specs/ = 214 catalogued EECH features with port-status columns (STALE — predate the 07-06
  gap-close clusters and all 07-07 fixes; journal explicitly says "update specs port-mapping").
- Known outstanding divergences from journals: snowball/strength-scaled top-N, capture-on-dispatch,
  STRENGTH_SURVIVAL 30→40, invented win condition (d) "military collapse", MAX_ASSIGN_RANGE
  250→400k, rate_pos 2*damage term (flagged), vehicle reserve seed vs parser.c:1303, placeholder
  GARRISON vs wutcfg.c group_database, FOW radii DCS-attribute proxies, recycle-on-RTB proxy.
- User complaint class: mechanics implemented but NOT WIRED (imap-no-consumer, empty else at
  troop recon fork, offset=0 dead scheduler — all previously found instances of this class).

Plan: (1) single Fable audit agent reconciles specs/ + EECH source vs CURRENT Scripts/ —
per-feature verdict + a dedicated connectivity audit (exports→callers, schedulers→consumers,
S.* writers/readers, event handlers). (2) Triage into fix clusters. (3) Opus agents implement
sequentially, adversarial review per cluster, build/check/inject-verify each.

### Audit COMPLETE — GAP-ANALYSIS-2026-07-09.md written (single Fable agent, 214 features re-verified)
Verdicts: FAITHFUL 52 · PROXY 62 · DIVERGED 17 · DISCONNECTED 6 · MISSING-real 24 · MISSING-n/a 53.
Headline disconnections (the user's "lazy port" class, all confirmed in CURRENT code):
- BAI generator starved to death by the 200km is_near_friendly echelon band (CAS absorbs all).
- Artillery generator early-returns forever — campaign never spawns an Artillery-attribute unit.
- IMAP_SURFACE_DEFENCE computed for nobody (its only consumer, counter-battery reaction, unported).
- keysite.rate_pos = invented formula miscited to the BAI block; ignores the port's own imaps.
- capture-on-dispatch vs EECH capture-at-arrival; pending_captures module-local (lost on re-inject).
- 9 dead exports + main.lua legacy layer + write-only S.base_warehouse + dead "troop" ledger role.
Fix clusters A→J defined in the doc (each with exact EECH file:line). Tasks #1-#10 created.
Baseline gates green before work: build 29 modules 0 warnings; check 32 files no findings.
DCS Studio MCP not registered in-session → driving over HTTP via scratchpad mcp.sh (recipe from
07-06 journal; tools/list confirms full surface).

### Cluster A COMPLETE (strike targeting fidelity) — implemented + adversarially reviewed + fixed
- Opus agent realigned keysite.rate_pos to the REAL create_keysite_strike_tasks rating
  `1·(1-IMAP_AIR_DEFENCE) + 4·IMAP_BASE_DISTANCE + 2·(1-eff) + 2·side_ratio` (highlevl.c:1109-1127),
  reading the port's own imap layers (first real consumer of BASE_DISTANCE/AIR_DEFENCE in strike
  scoring). Weight profiles RATE_GROUND_STRIKE (max 9) / RATE_OCA_STRIKE (1/4/2 max 7,
  highlevl.c:1370-1381). Deleted: obj_boost, dead th param, installation STRIKE_VALUE table +
  finish-off bonus + strike_targets_ranked. Added: 0.75 ratio gate, recon-first fork
  (recon_target OR FOW<0.25 → recon; strike arrives via react_recon_complete_keysite), eff≥min
  gate, dedup vs live ground_strike/TI, OCA FOW≥0.25 + dedup. ONE ranked scan for airbases +
  installations. KEY FIDELITY SHIFT: airbases are recon_target=TRUE (ks_dbase.c:125) → EVERY
  airbase strike is now recon-first, exactly as EECH ("Strike Created Upon Reaction").
- Adversarial review (Opus) found 1 ship-blocker + 3 lesser: (#1 HIGH) installation dedup was
  INERT — create_strike_task only set target.base for airbases, so has_task_against never matched
  installations → re-tasked every 450s cycle, striker drain. FIXED: target.base=tname always +
  register_task now covers installations too (in-flight dedup; BIRTH CAP no-ops via nil base_pos =
  faithful to factory requires_cap=FALSE ks_dbase.c:214) + reaction.efficiency_of reads
  S.keysites[].health (destroyed installation no longer reads eff=1.0). (#3) installations.FLAGS
  recon_target corrected to real ks_dbase rows (factory/port FALSE :219/:360; refinery/power/
  radar/depot/command TRUE) — data corrected, funnel still direct-strikes installations as a
  documented proxy until Cluster I makes the reaction chain kind-aware. (#4) recon-dedup set
  comment: port's single troop_insertion type covers both EECH troop task types.
- LIVE-SOAK WATCHLIST (review #2): RESERVE_PER_BASE.recon=1 is now load-bearing (every airbase
  strike needs a recon first) — watch for recon-pool starvation throttling the strike spine.
- CLUSTER I ADDITION: kind-aware keysite_flags + installation recon fork (honour corrected FLAGS).
- Gates: build 29 modules 0 warnings; check 32 files no findings.

### Cluster B COMPLETE (echelon wiring — BAI un-starved)
- EECH CORRECTION found by the implementer: INT_TYPE_FRONTLINE is NOT a sector distance — it is
  group_database[sub_type].frontline_flag (gp_int.c:389-392), a STATIC per-group-TYPE flag
  (NONE=0/PRIMARY=1/SECONDARY=2/ARTILLERY=3, group.h:199-202). CAS keeps ==1 (highlevl.c:877),
  BAI keeps >1 (:637), SEAD keeps AA with flag NONE (:1981). Port groups are undifferentiated →
  positional Gabriel proxy: frontline.echelon_of(pos) = nearest owned base's frontline flag →
  "frontline"(CAS)/"second"(BAI/SEAD). Deleted invented FRONTLINE_RADIUS 200km + is_near_friendly.
  is_frontline has its first real consumer. SEAD generator now excludes frontline-attached AA
  (spawn_sead_against reaction untouched). *-scan split logs added for live validation.
- FOLD INTO CLUSTER F: once F differentiates ground group types (PRIMARY tanks / artillery /
  SECONDARY), echelon classification should move to group TYPE per gp_int.c — positional proxy
  stays as fallback.
- Adversarial review: B clean (no dangling refs, echelon safe, Gabriel graph thin → no BAI
  re-starvation, SEAD ring intact).

### Cluster C COMPLETE (capture on arrival) — implemented + reviewed + hardened
- Capture now fires per mb_msgs.c:2260-2325: Insert- heli reaches the TROOP_CAPTURE waypoint at
  its keysite → roll d=(eff−min)/(1−min) × members/(members+losses) vs frand, members/losses
  sampled from the GROUP at arrival (:2293-2295), eff read at the event (:2283). Defender backup
  insertion added to the periodic generator (highlevl.c:1876-1897: enemy-owned, defender dedup,
  <2 patrols, NO eff gate). run_troop_insertion export unchanged.
- Adversarial review CRITICAL caught + FIXED (by me): check_landing_helis scanned ALL enemy bases
  within 8km of the flight path → overflights could capture non-targeted, partially-healthy bases
  (57-86% roll chance at eff 0.4-0.6!), and defender-backup helis could capture attacker bases en
  route. Fix: proximity tested ONLY against the heli's registered task target_base. ALSO removed
  the uncited CAPTURE_DELAY=150s window entirely — EECH rolls IMMEDIATELY at the waypoint event
  (mb_msgs.c:2305); pending-window state replaced by a resolved-once marker map
  (S.pending_captures = group_name→true), eliminating the reviewer's stale-window finding too.
- Gates after fixes: build 29 modules 0 warnings; check 32 files no findings.

### Cluster F IMPLEMENTED (force composition & escalation) — review found 7 fixes, agent re-fixing
- Landed: all-tank GndCol 7±2 (faction.c:1540-1542, gp_dbase.c:723); NEW Arty- SP-artillery groups
  (1/frontline base, tube/MLRS alternating per faction.c:1624-1633, S.arty_groups registry,
  vehicle-consume+refund); run_artillery ALIVE (attribute OR ^Arty prefix; enemy batteries into
  counter-fire set); NEW reaction.on_artillery_fire counter-battery (reaction.c:703-810: rating
  (1−AIRDEF)+SURFACE_DEFENCE+2·BASE_DISTANCE max 4, FOW>0.5→BAI else RECON) — IMAP_SURFACE_DEFENCE
  finally has its consumer; WAVE phase table DELETED (STRIKE_PACKAGE_SIZE=2; escorts by
  cs.route_difficulty/escort_count per task.c:890-907 + assign.c:598-627, thresholds 3/3/5/3,
  CRITICAL=6; SEAD flights + TI now threshold-escorted); phases demoted to display-only;
  order.c:361 garrison miscitation removed; echelon now BY GROUP TYPE (GndCol→PRIMARY, Arty→ARTY,
  -def→SECONDARY per gp_int.c:389-392) with positional fallback. PROVENANCE CORRECTION: escort
  thresholds are warzone DATA (wutcfg.c:1590/:825), not ts_dbase constants (shipped defaults are
  all ESCORT_NEVER=15) — documented as researched warzone data.
- NEW DCS types (UNVERIFIED-IN-LIVE-DB, added to test/spawn_test.lua): M-109, MLRS, SAU Msta,
  Grad-URAL — must pass spawn_test next live session.
- Adversarial review: F1 HIGH escort >>1 halving on coarse base-sectors → difficulty never reaches
  threshold (escorts vanish, TI escort regressed); F2 MED/HIGH vehicle pool not raised for 2×
  frontline-base demand (arty+tank) → under-fielded OOB; F3 addGroup throw leaks vehicle; F4
  counter_battery dedup never pruned; F5 ARTY_GROUP_SIZE 5>EECH cap 4 (gp_dbase.c:810); F6 untagged
  patrols positionally echeloned → CAS/BAI-target patrols EECH ignores (flag NONE matches neither);
  F7 pre-existing: run_cas/run_bai/run_oca_sweep imap.get(enemy,AIR_DEFENCE) orientation INVERTED
  (reads attacker's own AA). All 7 sent back to the implementer agent (running).

### Cluster F review fixes LANDED (all 7) + Cluster D COMPLETE (parallel, file-isolated)
- F fixes: (1) route_difficulty >>1 halving removed (fine-grid calibration doesn't transfer to
  bases-as-sectors; 60km defended leg now = difficulty 4 ≥ threshold 3 → escorts + TI escorts
  restored); (2) init_oob tops up vehicle pool to 2×frontline-base demand (parser.c:1397-1435
  reserve-covers-placement analog); (3) pcall'd ground addGroup + refund-on-throw; (4)
  counter_battery dedup pruned on read; (5) ARTY_GROUP_SIZE 5→4 (gp_dbase.c:810 cap); (6) ^Patrol
  → frontline_flag 0/NONE → excluded from BOTH CAS and BAI (gp_int.c:389-392); (7) imap AIR_DEFENCE
  orientation fixed in run_cas/run_bai/run_oca_sweep (+ coordinator fixed the same inversion in
  troop.lua:419 TI scorer the agent flagged). Gates green.
- Cluster D (task_board only, parallel-safe): flat MAX_ASSIGN_RANGE=400km replaced by the EECH ETA
  gate — accept iff distance ≤ cruise_speed(role) × expire_timer(type)
  (group.c:245-336 assess_group_task_locality_factor, quoted). CRUISE_SPEED per role = the port's
  actual route speeds (striker/escort 220, recon 300, heli 55, transport 100 m/s, each cited to
  its module). Effective ranges: ground_strike 528km · oca/sead 396km · TI 270km · recon 180km ·
  bda 99km · cas/bai 66km · heli_escort 33km — helis now correctly FARP-local, fixed-wing keeps
  its legitimate long reach. Also added per-keysite assign budget 3/pass (assign.c:218,
  ks_dbase.c:118). Gates green.

### Clusters E, I, G, H, J COMPLETE (all Opus-implemented, gates green after each)
- E: criterion (d) deleted (fc_msgs.c has exactly 3 end conditions, quoted); ALL STRENGTH_SURVIVAL/
  DEFEAT gates + constants deleted (force_attitude verified: parsed, NEVER consumed by EECH AI —
  no survival mode exists); game_over reclassified — 12 generators skip-body-keep-ticking,
  infrastructure (fow/imap/repair/board/regen/overlay/status) keeps running. NOTE (user call
  someday): the literal C never gates generation post-victory at all (highlevl.c never reads
  SESSION_COMPLETE; fc_msgs.c:163 is a re-award guard) — generator suppression is a documented
  proxy; full-continuation is a trivial widening if wanted.
- I: run_oca_sweep target override (reaction.c:469-471); invented re-strike dedup REMOVED
  (reaction.c:659-674 unconditional); SEAD ring FOW>0.25 gate (highlevl.c:2653); UNDER-ATTACK CAP
  (keysite.c:854-939 — 900s duration keysite.c:915, assist 60±20s keysite.h:67, fires from
  structure damage → covers HUMAN attacks, MP-critical); keysite-loss task termination in
  do_capture (keysite.c:1229-1260 via destroy_keysite, both sides' tasks); KIND-AWARE keysite
  flags (full ks_dbase rows per kind — FARP oca_target=FALSE fixed; factory TI=TRUE encoded
  truthfully, port TI follow-on gated to basing keysites as documented proxy); installation recon
  fork now honours per-row recon_target. Agent ran its own scoped review; fixed a BDA-on-factory
  regression (recon_target gate, reaction.c:676).
- G: FARP drain -0.05/-0.03 (ks_dbase.c:239-240); REPAIR_MIN_SUPPLY DELETED (ks_updt.c:169-222 —
  no supply gate in EECH); STRIKE_SUPPRESS_TIME kept, re-documented as the repair-task-delivery
  proxy; kill-proximity damage channel DELETED (keysite+installations apply_kill_damage,
  KILL_RADIUS/KILL_DMG — EECH strength moves only on building death; static-death + deterministic
  strike channels carry attrition; under-attack CAP rewired to strike_damage +
  register_static_death); HEALTH_NEUTRALISED unified to 0.3 = MINIMUM_EFFICIENCY.
- H: deleted fog_of_war.grant, keysite.best_friendly_*/behind_base, farps.is_heli_only,
  task_board.has_live_task_of_type_against, heli_war retired schedulers + 4 private helpers,
  main.lua legacy layer (~430→54 lines, spawn_queue still first), dead "troop" ledger role (fuel
  crates stop vanishing); S.base_warehouse kept + documented with the user's 07-07 decision.
- J: player task reservation (assign.c:220-255 semantics — 2 fresh non-critical flyable per pass,
  lapses by AGING at remaining<=180s, immediate bypasses) + regen player-landed veto
  (rg_updt.c:307-339 — own-side human on ground within 2km → delay not drop, read-only pcall).

### FINAL cross-cutting adversarial review (D/E/G/H/J + seams) → 3 fixes applied by coordinator
- Finding 1 HIGH: pilots.PLAYER_FLYABLE still listed RETIRED types (anti_armour/hunter_killer) →
  reservation + Request Mission menu INERT (the exact wired-but-disconnected class). FIXED →
  {cas, bai, troop_insertion, bda}.
- Finding 1b MED: global-2 reserve (vs EECH per-keysite 2) would hold ~half the rotary war on an
  EMPTY server once cas/bai became flyable. FIXED: reserve only while a human is connected
  (coalition.getPlayers), documented scale proxy.
- Finding 2 MED: eta_range used TOTAL expiry window; EECH's expire_timer counts DOWN
  (ts_updt.c:107) and group.c:314 compares vs REMAINING → radius must shrink with age. FIXED.
- Finding 3 LOW: 0.3-boundary semantics unified everywhere to EECH's inclusive-usable
  (USABLE iff eff >= min): task_board/regen/troop/transfer/keysite_repair gates + strike_damage
  neutralised banner now strict <. Orphan anti_armour/hunter_killer board rows removed
  (heli_escort kept — spawn_escort is live).
- Finding 4 INFO: deep >180km airbases unreconnable under the ETA gate = EECH-faithful behavior
  (front must advance); watch recon DENSITY (1/airbase) in soak.
- All clean otherwise: game_over seams, survival deletions, kill-handler chain, H sweep, regen
  veto, re-inject safety, dbg format args.
- Gates after fixes: build 29 modules 0 warnings; check 32 files no findings.

### LIVE VALIDATION (2026-07-10 session continuation) — first injection results
- Getting DCS up was its own saga: net.start_server eval BLOCKS past the bridge timeout; DCS
  loaded the mission but sat PAUSED + MINIMIZED, which also freezes the bridge's eval loop
  (latency=null, evals time out — remember this signature). User (AFK) authorized full screen
  control → built scratchpad screen.ps1 (CopyFromScreen) + input.ps1 (SetForegroundWindow/
  SW_RESTORE/clicks/SendKeys); restoring + focusing the DCS window UNPAUSED the sim and the
  bridge came back (latency 3ms). Injection then clean via net.dostring_in('server', dofile).
- VERIFIED LIVE (new mechanics all firing, 0 script errors):
  · Cluster B: "cas-scan: 6 groups, 3 frontline (cas), 3 second-line (bai)" — echelon split live,
    BAI has candidates for the first time ever.
  · Cluster A/I: strike funnel "14 cands -> 3 recon(fogged/recon_target)" — recon-first fork live
    for airbases AND installations (KStrikeRecon vs Gudauta/KS-factory/KS-port), reaction chain
    will deliver the strikes.
  · Cluster D: board funnel "in_range=3(<=180km)" — ETA gate live; CAS helis assigned to
    FARP-local tasks only (Heli-CAS from FARP-farp-3/4, both sides, AH-64D + Mi-24V).
  · Cluster F: Arty- groups spawned BOTH sides — ALL FOUR new DCS types accepted live
    (M-109, MLRS, SAU Msta, Grad-URAL) → unverified-type risk retired; vehicle top-up live
    ("topped up 4 -> 10 (2 x 5 frontline bases)"); under-attack reaction firing
    (react_to_offense at FARP-farp-3 on RED's strike).
- LIVE BUG FOUND + FIXED (the exact lazy-port class): artillery generator ran but assigned
  0 fire missions — batteries spawned HOLDING 1.5km behind their home base, permanently outside
  the 20km fire envelope, because spawn_arty_group's comment claimed EECH artillery "does NOT
  advance". WRONG: highlevl.c:433's advance filter is `if (frontline_flag)` — non-zero — so
  ARTILLERY(3) advances with the front like PRIMARY(1). FIX: advance_retreat step 2b walks each
  battery toward the nearest enemy base and halts at ARTY_STANDOFF=15km (inside the fire
  envelope, create_artillery_strike_tasks highlevl.c:2939-3081); re-routes when the front moves;
  prunes dead batteries. Build/check green; re-injected. NOTE: at COL_SPEED 8 m/s a battery
  needs ~20-40 min to drive into range — artillery fire missions + counter-battery will only be
  observable deep into a soak.

### Re-inject validation — artillery mobile, BAI FIRING both sides, log clean
- "5 arty advancing" at the first ground tick (BLUE batteries rolling toward FARP-farp-4, halt
  15km). BAI: BLUE "18 groups, 8 frontline, 10 second-line -> 10 rated" / RED "20 groups, 10/10"
  — the generator that was dead since the port began is running on both sides (currently
  FOW-forking to recon + sector-capping, exactly the EECH gates). The only stack tracebacks in
  the log are DCS's own WRADIO speech assert (phrase.lua — benign engine noise, not ours).
- Soak continues under a 1h monitor (artillery fire missions once batteries close to <20km at
  8 m/s ≈ 20-40 min, counter-battery funnel, captures). Screen-control toolkit for the AFK
  workflow lives in the session scratchpad (screen.ps1 / input.ps1) — recreate from this journal
  if needed: CopyFromScreen screenshot; SW_RESTORE+SetForegroundWindow to unfreeze a
  paused+minimized DCS (pausing freezes the bridge eval loop — latency=null is the tell).

### 6x soak (user accelerated) — 2 more live bugs found + fixed; artillery/counter-battery CONFIRMED
- CONFIRMED at 6x: artillery batteries drove to standoff and FIRED (both sides, ~T+16min);
  counter-battery BAI answered in BOTH directions (ratings 2.89-3.85/4.0 — SURFACE_DEFENCE term
  live); BAI generator scanning/forking every cycle; economy war (factories to 43%); campaign
  strength moving (BLUE 68/32). Zero campaign script errors.
- LIVE BUG 3 (lazy-port class): recon-first strike spine THROTTLED — 36 failed recon assignments
  in 30min. Root: recycle_side/convert_reserves credited FIXED-WING roles to heli-only FARPs
  (richest-base picker ignores base kind) → board assigns recon/striker from a FARP → builder
  fails at the padless base → refund to the SAME FARP → sticky loop. FIX: recycle_base now
  REDIRECTS fixed-wing credits (striker/escort/recon) from FARP/FOB to the side's richest
  fixed-wing-capable base (ks_dbase.c:255 FARP capacity is rotary; popread.c:1981-2019 no FW
  routes). Verified live: "credit redirected -> Kutaisi/Sochi-Adler/Batumi" lines flowing.
- LIVE BUG 4: EVERY SEAD builder threw "cas_bai_sead:273: attempt to index global 'supply'
  (a nil value)" — Cluster F's spawn_sead_escort referenced `supply` without requiring it.
  `check` does NOT flag unknown globals (analyzer blind spot — noted). FIX: local supply =
  require("supply"). Ran a precise undeclared-module-global sweep over all 29 modules: this was
  the ONLY instance. (Also: task_board's builder-error log line was what surfaced the real
  exception text — the logging pass keeps paying off.)
- Gates green after both fixes; gen-3 injected; soak monitor re-armed (captures, FW-at-FARP
  leaks on the consume side, SEAD escort spawns, artillery).

### GEN-3 SOAK: FULL CAPTURE CHAIN CONFIRMED END-TO-END — session goal met
- The complete EECH loop observed live in one sequence (00:09-00:14): producers neutralised
  (factory-4, port-1 → 0% "PRODUCER LOST") → FARP-farp-4 struck 46%→18% NEUTRALISED → BLUE T.I.
  dispatched + RED DEFENDER BACKUP T.I. (the new highlevl.c:1876-1897 generator branch, live!)
  → Insert heli reached the capture waypoint → roll with REAL inputs
  "capture_roll FARP-farp-4: eff=0.18 defence_score=-0.17 roll=0.58 -> CAPTURED" (mb_msgs.c) →
  "task-termination on capture: 6 task(s) cleared (keysite.c:1229-1260)" (Cluster I live) →
  +6 heli/+4 fw reseed with the FW credit correctly redirected to Batumi (supply fix holding) →
  size-aware FARP repair → BLUE holds it. Counter-battery attrited RED's batteries 3→1 with
  correct assist-dedup ("SKIP: already object of BAI/RECON"). No FW-at-FARP assignment recurred
  in gen-3. Campaign at T+217m [late]: BLUE 82/18, RED down to 3 keysites — resolving toward a
  BLUE win. Zero campaign script errors.
- SESSION GOAL MET: every mechanic from the gap analysis is implemented, EECH-cited,
  adversarially reviewed, and now OBSERVED live end-to-end. Four live-only bugs were caught by
  actually watching the run (artillery immobile; FW-credits-to-FARPs loop; SEAD undeclared
  global; plus the earlier per-cluster review fixes) — reinforcing that build/check green is
  necessary-not-sufficient (the analyzer misses unknown globals).

### Endgame observation (T+584m): tempo now RESERVE-BOUND — mechanics healthy, war slow-grinding
- BLUE 77-82 dominant; RED compressed to 3 keysites, its producers DEAD (factory/port/radar 0% —
  economic strangulation working as designed); FARP-farp being worn (100→72→84 cycling with
  repair); FARP-farp-4 contested at 1% (RED counter-pressure — front alive, not frozen).
- Task registry NOT deadlocked (LAND/completion dispatches flowing; funnel "deduped" = genuinely
  in-flight tasks). The real pace-setter: RESERVE EXHAUSTION — live combat helis 0 BOTH sides,
  escort stock 0 (oca_sweep unassigned "0 w/escort-stock"), recon expiring unassigned,
  board_failed=235. Production replacement (~1 aircraft/10min via convert_reserves round-robin)
  << late-war attrition. This is scenario-data territory (FORCE-F4: RESERVE_PER_BASE is
  designer-tunable warzone data; EECH warzone reserves are genuinely larger — hundreds per
  force). RECOMMENDATION for the user: bump RESERVE_PER_BASE (esp. recon 1→2-3, escort 4→8,
  heli) toward EECH-scale warzone numbers so the endgame can close; NOT auto-tuned mid-soak (a
  re-inject would reset this run).
- Win checks correct throughout: BLUE objectives 1/4, RED usable-airbases=3, criterion (c)
  correctly NOT firing on live=0 while reserve/regen stock exists.

### LIVE BUG 5 (user spotted on the map): artillery batteries piled up on one road
- All batteries heading for the same enemy base computed the IDENTICAL standoff halt point →
  5 columns converged on one road coordinate and jammed (DCS ground AI). AND reroute()'s
  terminal waypoint is "On Road" so even dispersed destinations snapped back onto the road line.
- FIX: (a) each battery takes its own SLOT on the standoff ring — deterministic lateral offset
  perpendicular to the approach, slot=(spawn id % 5)-2, 2 km apart (EECH spreads artillery
  across DISTINCT artillery nodes along the front, faction.c:1602-1661 — one node per group,
  never one shared point); (b) new arty_reroute(): approach On Road, final leg OFF Road
  ("Deploy") at the exact slot. Gates green, re-injected (gen-4).
- NOTE: reserve exhaustion means this fresh generation restarts the war with full pools — also
  a natural A/B of the endgame-tempo observation.

### LIVE BUG 6 (user spotted): "columns are nothing but M1A2s" — CONFIRMED misalignment
- Cluster F's "EECH frontline groups are ALL TANKS" was WRONG — a misreading of gp_dbase.c group
  LABELS. The real composition is DATA: setup/common/data/FORMCOMP.DAT (default formation-
  component DB, loaded en_forms.c:698), consumed slot-by-slot by create_faction_members
  (components[loop*2]=BLUE, [loop*2+1]=RED, first N slots in file order — faction.c:661/666).
- REAL compositions: PRIMARY_FRONTLINE (FORMCOMP.DAT:434) slots 1-7 = tank,tank,IFV,SHORAD
  (M1037 Avenger/SA-19),IFV,SAM(M48 Chaparral/SA-13),APC — COMBINED ARMS with ORGANIC AD.
  ARTILLERY_GROUP (:550)/MLRS (:567) COUNT=4 = 2 guns + truck + scout (NOT 4 guns).
  SECONDARY (:475) = tank/SAM/IFV/trucks/fuel/scout logistics echelon.
- Realignment dispatched to the Cluster F implementer agent (slot tables + verified-DCS-type
  mapping rules + echelon-interaction check for organic AD inside GndCol).

### FORMCOMP realignment LANDED (agent) — combined-arms compositions + a hazard it caught
- ground_forces.lua now encodes the ORDERED slot tables with per-row FORMCOMP.DAT line citations:
  PRIMARY_SLOTS (16 rows, :438-469 — 7-group = 2 tanks + 2 IFV + SHORAD + SAM + APC),
  ARTY_SLOTS/MLRS_SLOTS (:554-561/:571-578 — 2 guns + truck + scout). gp_dbase default types
  documented as fallback-only. 8 new UNVERIFIED DCS types flagged + added to spawn_test
  (2S6 Tunguska, BMP-3, M48 Chaparral, Strela-10M3, M-113, M 818, Ural-375, UAZ-469);
  verified substitutions documented (M1037→M1097 Avenger, M998→M1043 HMMWV, Ural-4320→Ural-375).
- HAZARD the agent caught during the echelon check: both target scans classify by unit(1)
  attributes; after attrition DCS compacts the unit list, so a surviving organic AD vehicle at
  unit 1 would silently reclassify a whole GndCol as an AA group (dropped from CAS/BAI, SEAD'd
  instead). FIXED: name-tag priority in both scans — tagged campaign groups are always ground
  targets and never SEAD targets (EECH frontline_flag is per GROUP TYPE, gp_int.c:389-392;
  SEAD wants air_attack==10 site AA, highlevl.c:1981, PRIMARY's stat is 6, gp_dbase.c:732).
- Gates green; gen-5 injected; verifying mixed columns live.

### Gen-5 LIVE VERIFICATION: combined-arms columns confirmed unit-by-unit
- Live getUnits() query: GndCol-2-2007 = M-1,M-1,Bradley,M1097 Avenger,Bradley,M48 Chaparral,
  M-113,M-1,M-1 (9-slot); GndCol-1-2015 = T-80UD,T-80UD,BMP-2,2S6 Tunguska,BMP-3,Strela-10M3,
  BTR-80 (7-slot) — EXACT FORMCOMP slot order both sides. Arty groups = 2 guns + truck + scout
  (M-109/M 818/M1043 HMMWV · SAU Msta/Ural-375/UAZ-469 · MLRS + Grad-URAL variants).
- ALL 8 previously-UNVERIFIED DCS types spawned as LIVE UNITS (2S6 Tunguska, BMP-3, Strela-10M3,
  M48 Chaparral, M-113, M 818, Ural-375, UAZ-469) — live-verified, stronger than spawn_test.
- User's "nothing but M1A2s" report fully resolved; compositions now trace to FORMCOMP.DAT rows.

### CONFIG LOADER built (user feature request) — the port's "warzone data file"
- NEW config.lua (30th module): DEFAULTS for ALL scenario data (aircraft/ground types incl.
  FORMCOMP slot tables, statics triples, payload pylons, reserves, countries, theatre knobs),
  deep-merged under author-set _G.DMT_CONFIG (string side keys "blue"/"red", arrays replace
  wholesale), exposed as config.C + _G.DMT_ACTIVE_CONFIG. load_and_validate runs in main.lua
  AFTER reset, BEFORE game_loop: Unit.getDescByName probes every unit type; structure checks for
  statics/pylons (spawn-time-verified only — documented per the 07-06 crash saga); bad USER value
  → INVALID log + fallback to default; missing DEFAULT type (the AH-64D-module class) → loud
  outText with the fix. EECH-cited constants deliberately NOT configurable (prime directive) —
  config is the warzone-data layer, exactly EECH's own C-vs-FORMCOMP/WUT split. README gained a
  "Configuring the campaign (DMT_CONFIG)" section. ~12 modules hoisted; PURE hoist verified.
- Adversarial review: architecture clean (load order/merge/in-place validation verified NOT to
  have the stale-defaults trap). 4 findings → sent back for fix: (1) HIGH farp_front_dist
  hoisted as 200km but the 07-06 journal records 260km ("FRONT_DIST 260km → 19 FARPs") — drift;
  (2) MED wrong-typed override (scalar where table) CRASHES validation → boot abort, needs
  branch type-guards; (3) MED theatre section unvalidated (string front_dist crashes at
  frontline-scan time); (4) LOW leftover side-key typos ("BLUE") silently ignored. Fixes in
  flight (config agent).

### Config review fixes LANDED (all 4) — and the hoist SURFACED pre-existing drift
- farp_front_dist: the 200000 in farps.lua was itself unjournaled drift (07-06 journal:523 says
  260km); realigned to 260000 with citations. front_dist=140000 verified as a true unification.
- Branch type-guards (deep_copy + ensure_table over every section — scalar-where-table now
  INVALID+default-subtree, never a throw); theatre numeric validation; loud no-op warning for
  wrong-case side keys. Harness now 9 tests incl. all crash paths. Gates: 30 modules 0 warnings,
  33 files no findings.
- GEN-6 injected with a live DMT_CONFIG demo: reserves.per_base recon=3/escort=8 (the reserve
  scale-up experiment, now author-side!), plus an intentionally-bad striker ("F-99 Bogus") and
  theatre.front_dist="far" to prove the INVALID+fallback path in the real mission.

### GEN-6 demo results: theatre catch + reserve overrides WORKED; DB probe had a REAL HOLE (fixed)
- theatre.front_dist="far" → INVALID + default ✓. reserves recon=3/escort=8 → applied (seed lines
  recon=6/escort=16 per side) ✓. BUT "F-99 Bogus" PASSED the DB check and became BLUE's active
  striker — this DCS build's Unit.getDescByName returns a STUB table for unknown types (echoes
  typeName, ~5 keys, EMPTY displayName, no attributes) instead of nil, so non-nil ≠ exists.
- FIX (config.db_exists): exists iff desc has a non-empty displayName OR a populated attributes
  table (both always present on real descs, both absent on the stub). Gates green (30/0, 33/0);
  gen-7 injected with the SAME demo config to prove the catch.

### GEN-7 CONFIRMED: db_exists stub fix works — "F-99 Bogus" → INVALID + fallback (active striker
### = F-16C bl.52d). Config feature COMPLETE and live-proven end-to-end.

### LIVE BUG 7 (user): "bases are totally undefended" — EECH rings keysites with AD
- Causes: base_defenses returned EARLY in zone mode (over-application of register-don't-spawn,
  which governs ASSETS not units); empty→template never covered airbase/farp (07-07 leftover);
  author-placed AD wiped by 7 re-injects (accepted reset.nuke behavior).
- EECH truth: popread.c:2148-2212 — every population AAA/SAM point spawns an ANTI_AIRCRAFT group
  (LIGHT_SAM_AAA_GROUP, FORMCOMP.DAT:535-545, first count-1=2 slots per popread.c:2208: BLUE
  Chaparral+Vulcan / RED SA-19+SA-13); airfield/town templates carry several points each
  (TEMPLATE_TYPE_AIRFIELD/AAASAM popread.c:100-101); density is MAP DATA → per-keysite count is
  a config designer proxy. HEAVY_SAM_AAA exists in data, NO code consumer — not ported.
- IMPLEMENTED (base_defenses rewrite): AD rings in BOTH theatre modes — airbase=3 / farp=1 /
  installation=1 groups (config `defenses` section: groups_per/ring_radius/composition, all
  validated), templated keysites skipped (they have -aaa/-sam), regarrison on capture rewired
  into do_capture (S.base_ad_groups registry), FREE OOB (popread placement, not force reserve),
  AD-<base>-<n> names verified SEAD-able (flag NONE, not campaign-tagged) + feed imap
  AIR_DEFENCE + excluded from CAS/BAI. Also killed the old invented Kub/Roland garrison in
  config types.ground.base_defense (latent tuned-by-feel bug). Gates green. Gen-8 injected
  (clean config: reserves recon=3/escort=8 only).

### GEN-8 VERIFIED: 19 AD rings live, exact FORMCOMP compositions per side (Chaparral+Vulcan /
### Tunguska+Strela-10M3), 3 per airbase, SEAD-able. Bases defended.

### UNIT-PLACEMENT COMPLETENESS SWEEP (user asked "anything else missing?") — 2 gaps found+closed
- Full EECH world-gen placement inventory vs port: PRIMARY ✓, ARTY/MLRS ✓, AD rings ✓, patrols ✓,
  air OOB = documented ledger proxy, divisions = naming-only. MISSING: (A) SECONDARY frontline
  groups (faction.c:1583, FORMCOMP.DAT:475-511 — tank/SAM/IFV/trucks/fuel/scout logistics echelon
  — the CANONICAL BAI targets), (B) population FIRING POINTS (popread.c:1389-1439 — single-unit
  STATIC_INFANTRY MG posts + standing/kneeling MANPADS linked to the closest keysite).
- IMPLEMENTED: (A) GndSec- group per frontline base (7±2 first-N secondary slots; 3 NEW types
  M978 HEMTT Tanker/ATZ-10/BRDM-2 all desc-verified), spawned 4km rear, FOLLOWS the front at
  10km standoff behind the nearest friendly frontline base (advance step 2c, arty_reroute +
  slot dispersion), S.sec_groups registry, vehicle-consume; init_oob top-up 2×→3× frontline
  bases. ^GndSec → flag SECONDARY(2) → BAI-eligible, never CAS/SEAD. (B) FP- single-unit groups
  scattered in keysite footprint (Soldier M4/Infantry AK MG + Soldier stinger/SA-18 Igla manpad,
  all verified), FREE OOB, config defenses.firing_points {airbase=4,farp=2,installation=2},
  re-manned on capture via regarrison; ^FP- → flag NONE → neither CAS nor BAI nor generator
  SEAD; DELIBERATELY still visible to reaction.create_sead_around_keysite (EECH highlevl.c:2620
  filters default_entity_type==ANTI_AIRCRAFT which STATIC_INFANTRY is, gp_dbase.c:876).
- Gates green; gen-9 injected (census pending).

### GEN-9 CENSUS VERIFIED — placement layer COMPLETE
- Live: GndCol=8, GndSec=8, Arty=8, AD rings=35, FP=62. Sample secondary (RED) unit-by-unit =
  T-80UD, Strela-10M3, BMP-3, Ural-375, T-80UD, ATZ-10, BRDM-2 — EXACT FORMCOMP.DAT:479-492
  slots 1-7. New types ATZ-10/BRDM-2 (+HEMTT BLUE-side) spawned as live units.
- EECH world-gen placement inventory now fully closed: PRIMARY + SECONDARY + ARTILLERY/MLRS
  groups, AD rings, firing points (MG+MANPAD), patrols; air OOB stays the documented ledger
  proxy; divisions naming-only; ships n/a.

### PHYSICAL SUPPLY FLIGHTS implemented (user: "EECH transports flew resupply in") — closes the
### last documented economy proxy (03-F7 instant crate delivery + no closest-producer)
- EECH chain cited end-to-end: keysite.c:469 (cargo<=75 → FORCE_LOW_ON_SUPPLIES) →
  fc_msgs.c:672-848 response (CLOSEST producer: ammo→factory→refinery-fallback, fuel→reverse,
  nearer airbase substitutes, :756-800; dedup one task per consumer per commodity :721-742;
  movement_type AIR HARDCODED — land-convoy branch commented out in shipped source :834-846) →
  taskgen.c:1638-1727 create_supply_task (PICK_UP→PREPARE 4km→DROP_OFF→FINISH, expire 20min
  :1696). ts_dbase.c:1386-1440 supply row: priority 4, escort threshold 6, FW-transport+heli
  landing types, NOT reaction-offensive.
- NEW supply_flight.lua (31st module): request (dedup + installations.nearest_producer +
  crate-earmark), builder (crate debit AT PICK-UP; C-130/An-26B fixed-wing airbase↔airbase or
  transport heli for padless FARPs — config types.aircraft.transport_fw; producer re-resolved at
  spawn), arrival scan (4km DROP_OFF flyover → restock to 100, once-guard, captured-mid-flight
  → crate lost), RTB-recycle as transport / one-shot for regen (matches Insert-). Shot down =
  crate LOST = interceptable economy. EARMARK system stops convert_reserves eating requested
  crates. keysite_repair instant delivery REPLACED by sf.request. Scoped adversarial review run
  by the implementer: 3 low fixes applied (padless FW guard, captured-consumer guard, producer
  re-resolve), 2 documented-acceptable.
- Gates: build 31 modules 0 warnings; check 34 files no findings. Gen-10 injected; supply
  lifecycle monitor armed (first requests expected once bases drain below 75 — ~10-20 real min
  at 6x for airbases).

### LAND-SNAP implemented (user: "watch out for water") — the careful version, old failure avoided
- cs.snap_land(x,z,fx,fz) in campaign_state: table-return {x=,z=} (analyzer-safe by construction
  — the old snap died on multiple-return nil-narrowing), pcall-guarded land.getSurfaceType,
  deterministic 8-bearing × {200,500,1000,2000,4000}m spiral, ≤40 probes, fallback = caller's
  base/keysite centre; dry = LAND(1)/ROAD(4)/RUNWAY(5). LIVE-PROBED before finalizing: enum
  confirmed, Batumi runway=5 dry, move path found land at r=500 from a real water point,
  deep-sea fallback bounded.
- Applied at 12 call sites: AD rings, firing points, GndCol/arty/secondary spawn origins, arty+
  secondary standoff DESTINATIONS (fallback = current pos → hold, never march into the sea),
  template building grid per-cell + all 4 defence-ring origins (fixes the OLD coastal drops:
  "factory 5/7 at Batumi", "def only ~4 survived"), auto-mode installation ring, patrol ring,
  forward-FARP placement. Air routes/parking/authored centres untouched.
- Gates: 31 modules 0 warnings, 34 files no findings. Gen-11 injected.

### GEN-11 LIVE VERIFICATION — land-snap + supply flights BOTH PROVEN
- SNAP: 11 water placements (surf=3) rescued at boot across 4 coastal keysite clusters
  (r=200-2000m spiral hits). Zero errors.
- SUPPLY: full pipeline observed in EECH order — drain to <75 → "no crate banked -> no flight"
  (production-gated) → crate banked at 10.0 → earmark → board-assigned →
  "Supply-Batumi-fuel-2-2203 DISPATCHED: fuel pick-up @ KS-port-port -> drop @ Batumi (UH-1H)"
  → FIRST DELIVERY: "Supply-Kutaisi-fuel-2-2204 reached Kutaisi (634m): fuel restocked to
  100% — RTB". Three flights airborne (2 BLUE, 1 RED); crates debited at pick-up.
- Session watch persistent (deliveries/losses/captures/victory/errors).

### LIVE BUG 8 (user: "yet to see a C-130"): instant-delivery — launch base == consumer
- Timestamps proved it: Supply-Kutaisi-fuel-2-2204 "dispatched" 13:20:55, "reached Kutaisi"
  13:21:15 — spawned parked inside its own 4km delivery radius. EECH FORBIDS start==requester
  (taskgen.c:1676 returns NULL). FIXES: (1) board try_assign skips the target base as launch
  candidate for exclude_target_base tasks (set by supply requests); (2) builder belt-and-braces
  abort on launch==consumer; (3) PICK-UP-BEFORE-DROP-OFF sequencing in the arrival scan
  (taskgen.c:1709-1711 waypoint order): consumer proximity only counts after the transport has
  been within 4km of the PRODUCER (task.picked_up flag) — no more cargo-less "deliveries".
- USER PREF: BLUE transport/BDA heli UH-1H → UH-60A Black Hawk (live-DB probed: UH-60A OK,
  UH-60L absent). config default changed (author can override via DMT_CONFIG).
- Gates green (31/34); gen-12 injected.

### HEAVY-LIFT TIER added (user remembered C-17s — CORRECT): gp_dbase.c MEDIUM_LIFT=C-130J/An-12B
### (:590-591), HEAVY_LIFT=C-17/IL-76MD (:631-632); suitable.c's landing-type gate lets BOTH fly
### SUPPLY, nearest-idle wins → port alternates medium/heavy per FW flight (mlrs_flag pattern,
### faction.c:1633 analog). config transport_fw_heavy: C-17A / IL-76MD (both live-DB probed OK;
### An-12 absent from DCS → An-26B stays the RED medium analog). Validation covers the new role.
### Gen-13 injected (also carries the gen-12 supply sequencing fix + UH-60A swap).

### Gen-13 supply sequencing VERIFIED live: UH-60A dispatched from FARP-farp-2 (≠ consumer),
### "PICK-UP confirmed at producer (2745m)" 2min into the flight. NOTE: the earlier "instant
### deliveries at 15:18" scare was a timeline misread — gen-12 injected 15:20, so those were the
### LAST pre-fix gen-11 flights. No regression.

### CROUTE PORTED (user: "kill corridor" — traffic all flies the same straight lines)
- EECH's answer was croute.c biased routing — recursive midpoint insertion picking the lowest
  rating along the perpendicular: elevation_bias×avg_elev + range_bias×|off-center|×max(elev,1)
  + side_bias×(enemy sector)×max(elev,1) (croute.c:1502-1553); AIR profile 5.0/0.5/1.0, legs
  split to 5km, 8 samples, prune at 0.94 (croute.c:126-135); smoothing pass (:1464). VALLEYS +
  OWN TERRITORY + dispersion = no corridor.
- NEW croute.lua (32nd module): faithful algorithm, bases-as-sectors side proxy, memoized
  land.getHeight, depth cap 6 (safety), 8-nav-per-leg DCS cap (documented trim), latent C bug in
  second_past_route (uninitialized best_point on short spans) NOT reproduced — documented.
  Wired into ALL 7 airborne builders (strikes/escorts/CAS/BAI/SEAD/sweep/recon/heli/TI/supply);
  CAP/BARCAP orbits + BDA loiter stay direct (on-station over friendly ground, documented).
- LIVE TERRAIN PROBE (Batumi mountains): sample row picked the 703m valley floor between
  1508/994m ridges — correct EECH asymmetry vs the equal-elevation centerline. Waypoint counts:
  120km leg → 31 generated → 12 pruned → 8 capped; 27km → 4; 7km → 1.
- Gates: 32 modules 0 warnings, 35 files no findings. Gen-14 injected.

### "100% PARITY, NO DEFERRALS" DIRECTIVE — five waves executed (all subagent-implemented)
- W1 consolidation: imap→S.imap (persistence surface), ONE prefix→role table (supply.PREFIX_ROLES,
  regen delegates), keysite.get/all unified accessor. Pure refactor, proven identical.
- W2 PERSISTENCE (33rd module persist.lua): dcs_studio.sqlite (file API is write-only!),
  versioned pure-Lua serializer (integer side keys survive; JSON wouldn't), snapshot of the data
  subset (handles stripped, timers rebased), two-phase restore in game_loop.start (data overlay
  post-init, ground-OOB respawn from summaries, seeding skipped), autosave 300s + on capture/win,
  config persistence{} DEFAULT DISABLED (workflows unchanged). Offline roundtrip proven; LIVE
  bridge check pending a running sim (DCS at menu since gen-14).
- W3 assignment fidelity: CAPTURE-TO-CAPTOR ledger (keysite.c:1375-1393 default branch — the old
  zeroing modelled command_line_capture_aircraft=FALSE, wrong default); MIN_IDLE per group type
  (gp_dbase minimum_idle_count: heli 2, striker/escort 1); TI-vs-airbase 2-ship (assign.c:386,
  offensive only); reaction tasks critical=TRUE threaded (counter-battery BAI is the C's one
  FALSE, reaction.c:788); unusable-base ×2 assign interval (ks_updt.c:120-123, every-other-pass).
- W4 MP/pilot: assign_to_player (no ledger/slot — human airframe isn't reserve; task leaves the
  AI pool per the reserve model); group-scoped F-10 Request Mission (functional); briefing
  templates (briefing.c analog, bearing/range); debrief loop per helicop.c:693-836 (mission
  points ×FAILURE 0/PARTIAL ¼/SUCCESS 1, missions_flown, AIR MEDAL 3-streak play_md.c:89/1304,
  PURPLE HEART damaged-but-landed :1245 via new S_EVENT_HIT, CAMPAIGN medal at win :1062);
  census counts humans (fc_updt.c has no exclusion) + explicit getPlayerName guard in regen.
- W5 final: dormant-FARP activation (keysite.c:507-568 in_use latch, sector-side proxy, config
  theatre.farp_activation); S.stats per side + F-10 Campaign Stats (force.h:98-99 kills/losses);
  completion assessment (task.c:347-427 eff-based SUCCESS/PARTIAL/FAILURE → debrief+stats); task
  arrows RE-ENABLED (id band 20000-20399, cs.task_end_hook via clear_task + 30s GC — GOAL P1
  closed); campaign_mode.lua (campaign/skirmish cadence tables, highlevl.c:220-242, campaign
  byte-identical verified); POST-VICTORY LITERAL (all generator suppressions removed —
  fc_msgs.c:163 is only a re-award guard; the war continues after the banner).
- CROSS-WAVE ADVERSARIAL REVIEW: verdict ship-with-persistence-off; 5 fixables dispatched to the
  W5 agent: F1 MED farp_active must be recomputed after restore (over-activation never heals —
  pollutes win census on every server restart); F2 stats not persisted; F3 FW regen queued at
  captured FARPs (dead slots); F4 player TI can't capture + no player arrows; F6 stale comments.
  Cleared: campaign cadences byte-identical, imap-orphan seam safe, capture reseed NOT
  double-stacked (EECH does both, keysite.c:1375+1483), restore double-consume absent, MIN_IDLE
  no hard starve, signature drift none.

### Review fixes LANDED (all 5) + v0.2.0 RELEASE CUT
- F1 farp_active recomputed after restore (game_loop.lua:182-189, EECH re-runs
  initialise_keysite_farp_enable at boot); F2 stats persisted + farp_active documented-dropped;
  F3 FW reseed gated to airbase kind (captured FARPs queue heli only); F4 player TI can now
  capture (check_landing_helis accepts player==true troop_insertion tasks) + player arrows drawn;
  F6/F5 comments corrected/documented.
- RELEASE v0.2.0 (user: "build the mission into a bundle"): VERSION 0.1.0→0.2.0,
  game_loop.version bumped, CHANGELOG.md full-parity release entry written (fidelity
  realignments + new systems, all cited). Final bundle dist/dynamic-mission-test.lua:
  34 modules, 0 warnings, ~1MB, check 37 files no findings. Delivered to user.
- DCS was fully closed (not just menu) — relaunch started but the live-validation batch is
  handed to the next session.

## Next steps
- LIVE VALIDATION BATCH on v0.2.0 when the sim is next up: fresh single inject → waves 1-5
  smoke (stats line, arrows lifecycle, FARP dormancy latch, cadence roster, post-victory
  continuation) + persistence roundtrip (enable via DMT_CONFIG, autosave, restart, restore) +
  croute visual check + C-17/IL-76 supply rotation + player-path smoke (join, Request Mission,
  fly, debrief, medals).
- Soak to the declared win on v0.2.0.
- Soak toward a decisive declared win.
- Standing open items: persistence (P1), player mission assignment (P0-blocked), post-victory
  semantics user call, spec port-status column bookkeeping.
- User call: reserve scale-up (scenario data) for a decisive endgame, then a fresh full run.
- Multi-hour MP soak on a true dedicated server (goal-03 P0) with a human joining — exercises
  player reservation, regen player-landed veto, and under-attack CAP with a real player.
- Persistence (P1) — the last big missing subsystem (design serialization of S via dcs_studio
  bridge; imap layers still module-local, P2 prerequisite).
- Bookkeeping: update specs/ port-status columns for all closed gaps (10 files).
- Optional user call: post-victory semantics (generator-suppression proxy vs EECH's literal
  keep-generating).
- Run test/spawn_test.lua once for the record (M-109/MLRS/SAU Msta/Grad-URAL already spawned OK
  in-campaign — formal 34/34 pass still nice to log).
- Update specs/ port-status columns for the closed gaps (10 files) — bookkeeping, not code.
- Remaining real feature gaps (documented in GAP-ANALYSIS addendum): persistence (P1), player
  mission assignment (P0-blocked), deferred low-priority spec rows.

## Open questions
- Post-victory semantics: keep generator-suppression proxy, or widen to EECH's literal
  "everything keeps running" (highlevl.c never gates on SESSION_COMPLETE)? User call.

## Follow-ups & improvements
- Recon pool depth (1/airbase) is now load-bearing for the recon-first strike spine — if the
  soak shows strike starvation, the EECH-faithful lever is recon group density, not gate removal.
- Screen-control toolkit could move into .claude/skills/live-validation as the "DCS is paused/
  minimized and the bridge is dead" recovery recipe.

## Open questions
- none yet

## Follow-ups & improvements
- none yet
