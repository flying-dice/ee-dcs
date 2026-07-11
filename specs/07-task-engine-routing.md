# EECH Spec 07 — Task Engine, Assignment & Routing

Sources (all under `E:\eech_source_code\aphavoc\source\`):
- `entity/system/en_types/en_task.h`, `en_task.c` — task enums & name tables
- `entity/system/en_types/en_sbtyp.h` — TASK / WAYPOINT / LANDING / GUIDE sub-type enums
- `entity/special/task/ts_dbase.h`, `ts_dbase.c` — per-type task database (all 30 rows)
- `entity/special/task/task.h`, `task.c`, `ts_creat.c`, `ts_updt.c`, `ts_msgs.c` — task entity lifecycle
- `ai/taskgen/taskgen.c`, `taskgen.h` — task creation (`create_task` + per-type creators)
- `ai/taskgen/assign.c` — matching engine
- `ai/taskgen/engage.c` — engagement rules
- `ai/taskgen/croute.c` — route generation
- `ai/highlevl/suitable.c` — group↔task suitability matrix
- `entity/special/group/group.c` — group locality factor
- `entity/special/keysite/keysite.h`, `keysite.c`, `ks_updt.c`, `ks_creat.c` — assignment cadence, landing-site availability
- `entity/special/waypoint/wp_dbase.h`, `wp_dbase.c` — waypoint type database
- `entity/special/landing/landing.h`, `ld_creat.c`, `ld_msgs.c` — landing slot & lock allocation
- `entity/mobile/mb_msgs.c` — waypoint-reached → task-terminated hookups

## 1. Overview

EECH tasks are first-class entities (`ENTITY_TYPE_TASK`). Order generation (Spec 06 domain) calls `create_task()` which builds a task entity with a *specified route* (a short list of typed waypoints), an expiry timer, a priority, and an objective entity, and hangs it off a start keysite's UNASSIGNED_TASK list. Every keysite runs an assignment pass every 3 minutes: unassigned tasks are sorted by priority (critical ×2), some are reserved for the human player, and each remaining task searches the keysite's resident groups for the best *idle, awake, suitable, close-enough* group. Assignment builds a full waypoint route (terrain/side-biased recursive midpoint search), creates a GUIDE entity per task, pushes it on the group's guide stack, and moves the task to the ASSIGNED list. Tasks complete via stop-timer, waypoint-route-complete, or objective messages; completion is scored per-type (`assess_task_completeness`), the task moves to the COMPLETED list and self-destructs 20 minutes later. ENGAGE is a special non-primary "solo" task cloned per member against individual targets. Landing/takeoff at keysites is arbitrated by LANDING entities holding slot counts and bitmask locks.

Definition of terms (verbatim from eech `entity/special/task/ts_dbase.c:78-92`):
- **PRIMARY TASK** — main "mission"; group takes off, flies it, lands; updates force stats; rated on completion; may request escort; may re-link group to a new keysite; a group has at most ONE primary task.
- **SOLO TASK** — each mobile doing it gets its own guide entity (Landing, Engage, …).
- **PERSISTENT TASK** — not terminated/destroyed when a mobile completes it (Landing, Takeoff, …).
- **VISIBLE TASK** — shown to the user.

## 2. Data model

### 2.1 Task sub-type enum — 30 types (eech `entity/system/en_types/en_sbtyp.h:495-528`)

`ENTITY_SUB_TYPE_TASK_`: NOTHING, ADVANCE, ANTI_SHIP_STRIKE, BAI, BARCAP, BDA, CLOSE_AIR_SUPPORT, COASTAL_PATROL, COMBAT_AIR_PATROL, ENGAGE, ESCORT, FREE_FLIGHT, GROUND_STRIKE, LANDING, LANDING_HOLDING, OCA_STRIKE, OCA_SWEEP, RECON, REPAIR, RETREAT, SEAD, SUPPLY, TAKEOFF, TAKEOFF_HOLDING, TRANSFER_FIXED_WING, TRANSFER_HELICOPTER, TROOP_INSERTION, TROOP_MOVEMENT_INSERT_CAPTURE, TROOP_MOVEMENT_INSERT_DEFEND, TROOP_MOVEMENT_PATROL.

### 2.2 Task enums (eech `entity/system/en_types/en_task.h`)

| Enum | Values | Source |
|---|---|---|
| TASK_CATEGORY_TYPES | RECON, STRIKE, SUPPORT, MISC | en_task.h:67-75 |
| TASK_STATE_TYPES | UNASSIGNED, ASSIGNED, COMPLETED | en_task.h:83-90 |
| TASK_COMPLETED_TYPES | INCOMPLETE, COMPLETED_FAILURE, COMPLETED_PARTIAL, COMPLETED_SUCCESS | en_task.h:98-107 |
| TASK_TERMINATED_TYPES | IN_PROGRESS, EXPIRE_TIME_REACHED, ABORTED, GROUP_DESTROYED, OBJECTIVE_MESSAGE, STOP_TIME_REACHED, WAYPOINT_ROUTE_COMPLETE | en_task.h:115-127 |
| TASK_TARGET_SOURCE_TYPES | SCAN_AIR, SCAN_ALL, SCAN_GROUND, OBJECTIVE_NOMINATED, TASK_OBJECTIVE, NONE | en_task.h:135-146 |
| TASK_TARGET_TYPES (bit flags) | NONE=0, AIRBORNE_AIRCRAFT=1<<0, ANTI_AIRCRAFT=1<<1, ANY=1<<2, BUILDING=1<<3, BRIDGE=1<<4, CARGO=1<<5, COMMS=1<<6, FACTORY=1<<7, FIXED_WING=1<<8, GROUNDED_AIRCRAFT=1<<9, HELICOPTER=1<<10, MOBILE=1<<11, PEOPLE=1<<12, POWER=1<<13, ROUTED=1<<14, SHIP=1<<15, VEHICLE=1<<16 | en_task.h:154-179 |
| TASK_TARGET_CLASS_TYPES | ALL, AIR, GROUND | en_task.h:185-195 |
| TASK_OBJECTIVE_PREVIEW_TYPES | NONE, STILL, LIVE | en_task.h:201-211 |
| TASK_ROE_TYPES | NONE, OBJECTIVE, ALL | en_task.h:217-226 |
| TASK_OBJECTIVE_INFO_TYPES | NONE, ALWAYS_UNKNOWN, FOG_OF_WAR_KNOWN, ALWAYS_KNOWN | en_task.h:232-242 |

Status strings: `task_status_names` = "In Progress"/"Failed"/"Completed"/"Completed" (eech en_task.c:73-81); `task_debrief_result_names` = "In Progress"/"Failed"/"Partially Completed"/"Successfully Completed" (eech en_task.c:87-95).

### 2.3 TASK entity struct (eech `entity/special/task/task.h:102-168`)

Key fields: `sub_type`; `task_state`; `position`; `route_nodes` (vec3d*); `task_user_data` (per-type baseline: e.g. member count or keysite efficiency at creation); `task_priority`; `rating` (0..1 success rating); `start_time`; `stop_timer`; `expire_timer`; `return_keysite`; `route_dependents`/`route_formation_types`/`route_waypoint_types` (parallel arrays for the specified route); list roots `guide_root, player_task_root, task_dependent_root, waypoint_root`; list links `pilot_lock_link, sector_task_link, task_dependent_link, task_link` (task_link serves both unassigned and assigned lists — task.h:143), `update_link`; `task_terminated`; `task_kills`/`task_losses` (linked lists of `task_kill_loss_data`, task.h:67-96); bitfields: `awarded_medals, awarded_promotion, task_id, task_completed, route_check_sum, kills, losses, player_task, movement_type, difficulty, critical_task, task_score, route_length, side` (task.h:153-167).

### 2.4 Task database struct (eech `entity/special/task/ts_dbase.h:67-139`)

`task_data` fields, in database row order: `full_name, short_name, key`; `task_category`; `task_priority` (float); `difficulty_rating`; `task_default_target_class`; `task_default_target_source`; `task_default_target_type`; `task_objective_info`; `minimum_member_count`; `rules_of_engagement`; `engage_enemy`; `escort_required_threshold`; `waypoint_route_colour`; `add_start_waypoint`; `primary_task`; `solo_task`; `persistent_task`; `visible_task`; `keysite_air_force_capacity`; `assess_landing`; `task_route_search`; `perform_debrief`; `delay_task_assignment`; `task_objective_preview`; `counts_towards_player_log`; `wait_for_end_task`; `player_reserve_factor`; `task_pass_percentage_partial`; `task_pass_percentage_success`; `task_completed_score`; `movement_type`; `landing_types` (bitmask of `ENTITY_SUB_TYPE_LANDING_*`); `ai_stats` {air_attack_strength, ground_attack_strength, movement_speed, movement_stealth, cargo_space, troop_space}.

Constants: `ESCORT_NEVER = 15` (eech ts_dbase.h:154), `ESCORT_CRITICAL = 6` (eech ts_dbase.h:156).

Landing sub-types (eech en_sbtyp.h:424-432): FIXED_WING, FIXED_WING_TRANSPORT, HELICOPTER, GROUND, PEOPLE, SEA. Keysite air-force capacity enum: NONE, SMALL, LARGE (eech `entity/special/keysite/keysite.h:79-81`).

### 2.5 Task database — ALL 30 rows (eech `entity/special/task/ts_dbase.c:99-1929`)

DATA-DRIVEN caveat: the WUT mods removed `const` so `gwutcfg.c`/`wutcfg.c` can overwrite parts of `task_database` at load (comment eech ts_dbase.c:97-98); values below are the compiled-in defaults.

**Table A — identity, targeting, engagement** (landing types abbreviated FW / FWT / HC / GND / PPL / SEA):

| Task | Key | Category | Priority | Difficulty | Target class | Target source | Default target type | Objective info | Min members | ROE | Engage enemy | Escort threshold | Movement | Landing types | Source (ts_dbase.c) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Nothing | — | MISC | 0 | 0 | ALL | NONE | NONE | NONE | 1 | NONE | F | NEVER | ALL | 0 (none) | :108-159 |
| Advance | ADV | SUPPORT | 9 | 0 | ALL | SCAN_ALL | MOBILE | NONE | 1 | ALL | F | NEVER | GROUND | GND | :167-218 |
| Anti-Ship Strike | NST | STRIKE | 7 | 4 | GROUND | NONE | SHIP | ALWAYS_KNOWN | 2 | ALL | T | 3 | AIR | FW+HC | :227-279 |
| BAI | BAI | STRIKE | 4 | 3 | GROUND | NONE | VEHICLE | ALWAYS_KNOWN | 1 | OBJECTIVE | T | NEVER | AIR | FW+HC | :288-340 |
| BARCAP | BAR | SUPPORT | 7 | 1 | AIR | SCAN_AIR | AIRBORNE_AIRCRAFT | ALWAYS_KNOWN | 1 | ALL | T | NEVER | AIR | FW+HC | :349-401 |
| BDA | BDA | RECON | 9 | 1 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | NEVER | AIR | HC | :410-461 |
| Close Air Support | CAS | STRIKE | 6 | 3 | GROUND | NONE | VEHICLE | ALWAYS_KNOWN | 2 | OBJECTIVE | T | NEVER | AIR | FW+HC | :470-522 |
| Coastal Patrol | CPTL | SUPPORT | 1 | 0 | ALL | NONE | NONE | NONE | 1 | ALL | F | NEVER | SEA | SEA | :531-582 |
| Combat Air Patrol | CAP | SUPPORT | 5 | 1 | AIR | SCAN_AIR | AIRBORNE_AIRCRAFT | ALWAYS_KNOWN | 1 | ALL | T | NEVER | AIR | FW+HC | :591-643 |
| Engage | ENG | MISC | 10 | 0 | ALL | TASK_OBJECTIVE | ANY | ALWAYS_KNOWN | 1 | OBJECTIVE | T | NEVER | ALL | FW+FWT+HC+GND+PPL+SEA | :652-708 |
| Escort | ESC | SUPPORT | 7 | 1 | ALL | SCAN_ALL | MOBILE | ALWAYS_KNOWN | 1 | ALL | T | NEVER | AIR | FW+HC | :717-769 |
| Free Flight | FREE | MISC | 7 | 1 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | NEVER | AIR | HC | :778-829 |
| Ground Strike | STK | STRIKE | 9 | 4 | GROUND | NONE | BUILDING | ALWAYS_KNOWN | 2 | ALL | T | 3 | AIR | FW+HC | :838-890 |
| Landing | — | MISC | 10 | 0 | ALL | NONE | NONE | NONE | 1 | NONE | F | NEVER | ALL | all six | :899-955 |
| Landing Holding | — | MISC | 10 | 0 | ALL | NONE | NONE | NONE | 1 | NONE | F | NEVER | ALL | all six | :964-1020 |
| OCA Strike | OCA | STRIKE | 6 | 4 | GROUND | NONE | GROUNDED_AIRCRAFT | ALWAYS_KNOWN | 1 | ALL | T | NEVER | AIR | FW | :1029-1080 |
| OCA Sweep | OCA | STRIKE | 7 | 4 | AIR | SCAN_AIR | AIRBORNE_AIRCRAFT | ALWAYS_KNOWN | 1 | ALL | T | NEVER | AIR | FW | :1089-1140 |
| Recon | REC | RECON | 7 | 1 | ALL | NONE | NONE | FOG_OF_WAR_KNOWN | 1 | NONE | F | NEVER | AIR | HC | :1149-1200 |
| Repair | REP | SUPPORT | 5 | 0 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | 5 | AIR | HC | :1209-1260 |
| Retreat | RET | SUPPORT | 9 | 0 | ALL | SCAN_ALL | MOBILE | NONE | 1 | ALL | F | NEVER | GROUND | GND | :1269-1320 |
| SEAD | SEAD | STRIKE | 9 | 4 | GROUND | NONE | VEHICLE | ALWAYS_KNOWN | 2 | OBJECTIVE | T | 5 | AIR | FW+HC | :1329-1381 |
| Supply | SUP | SUPPORT | 4 | 0 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | 6 | AIR | FWT+HC | :1390-1442 |
| Takeoff | — | MISC | 10 | 0 | ALL | NONE | NONE | NONE | 1 | NONE | F | NEVER | ALL | all six | :1451-1507 |
| Takeoff Holding | — | MISC | 10 | 0 | ALL | NONE | NONE | NONE | 1 | NONE | F | NEVER | ALL | all six | :1516-1572 |
| Transfer (FW) | TR | SUPPORT | 5 | 1 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | 6 | AIR | FW+FWT | :1581-1633 |
| Transfer (Heli) | TR | SUPPORT | 7 | 1 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | 7 | AIR | HC | :1641-1692 |
| Troop Insertion | TI | STRIKE | 10 | 2 | ALL | NONE | NONE | ALWAYS_KNOWN | 1 | NONE | F | 3 | AIR | HC | :1700-1751 |
| Troop Mvmt (Ins/Capt) | TM | MISC | 5 | 2 | ALL | NONE | NONE | NONE | 1 | ALL | T | NEVER | GROUND | PPL | :1759-1810 |
| Troop Mvmt (Ins/Def) | TM | MISC | 5 | 2 | ALL | NONE | NONE | NONE | 1 | ALL | T | NEVER | GROUND | PPL | :1818-1869 |
| Troop Mvmt (Patrol) | TM | MISC | 5 | 2 | ALL | NONE | NONE | NONE | 1 | ALL | T | NEVER | GROUND | PPL | :1877-1928 |

**Table B — flags, scoring, AI stats** (AI stats as AA/GA/Speed/Stealth/Cargo/Troop; flags T/F in order: AddStartWp, Primary, Solo, Persistent, Visible, AssessLanding, RouteSearch, Debrief, DelayAssign, PlayerLog, WaitForEnd):

| Task | Flags (Add/Pri/Solo/Pers/Vis/Land/Srch/Deb/Delay/Log/Wait) | KS capacity | Preview | Player reserve | Pass% partial | Pass% success | Score | AI stats | Source (ts_dbase.c) |
|---|---|---|---|---|---|---|---|---|---|
| Nothing | T/F/F/F/F/T/T/F/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :127-159 |
| Advance | T/T/F/F/T/F/F/T/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :186-218 |
| Anti-Ship Strike | T/T/F/F/T/T/T/T/T/T/T | SMALL | STILL | 3 | 25 | 50 | 750 | 0/5/3/0/0/0 | :246-279 |
| BAI | T/T/F/F/T/T/T/T/T/T/T | SMALL | STILL | 2 | 25 | 75 | 1000 | 0/6/2/0/0/0 | :307-340 |
| BARCAP | T/T/F/F/T/T/T/T/T/T/F | SMALL | NONE | 0 | 100 | 100 | 0 | 6/0/3/0/0/0 | :368-401 |
| BDA | T/T/F/F/T/T/T/T/T/T/F | SMALL | NONE | 3 | 100 | 100 | 1000 | 0/0/3/5/0/0 | :429-461 |
| Close Air Support | T/T/F/F/T/T/T/T/T/T/T | SMALL | STILL | 2 | 25 | 75 | 1000 | 0/8/2/0/0/0 | :489-522 |
| Coastal Patrol | T/T/F/F/T/T/T/T/T/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :550-582 |
| Combat Air Patrol | T/T/F/F/T/T/T/T/T/T/F | SMALL | NONE | 3 | 100 | 100 | 750 | 6/0/0/0/0/0 | :610-643 |
| Engage | F/F/T/F/F/F/F/F/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 (route colour RED, :669) | :671-708 |
| Escort | T/T/F/F/T/T/T/T/T/T/F | SMALL | LIVE | 3 | 25 | 100 | 1000 | 4/2/0/0/0/0 | :736-769 |
| Free Flight | T/T/F/F/T/T/T/T/T/F/F | SMALL | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :797-829 |
| Ground Strike | T/T/F/F/T/T/T/T/T/T/T | SMALL | STILL | 2 | 10 | 25 | 1000 | 0/8/0/0/0/0 | :857-890 |
| Landing | T/F/T/T/F/F/F/F/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :918-955 |
| Landing Holding | T/F/T/T/F/F/F/F/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :983-1020 |
| OCA Strike | T/T/F/F/T/T/T/T/T/F/F | LARGE | STILL | 0 | 10 | 33 | 0 | 0/6/5/0/0/0 | :1048-1080 |
| OCA Sweep | T/T/F/F/T/T/T/T/T/F/F | LARGE | STILL | 0 | 25 | 50 | 0 | 5/0/5/0/0/0 | :1108-1140 |
| Recon | T/T/F/F/T/T/T/T/T/T/F | SMALL | NONE | 4 | 100 | 100 | 1000 | 0/0/3/5/0/0 | :1168-1200 |
| Repair | T/T/F/F/T/T/T/T/T/F/F | SMALL | LIVE | 0 | 100 | 100 | 0 | 0/0/0/0/6/0 | :1228-1260 |
| Retreat | T/T/F/F/T/F/F/T/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1288-1320 |
| SEAD | T/T/F/F/T/T/T/T/T/T/T | SMALL | STILL | 2 | 10 | 100 | 1000 | 0/6/0/0/0/0 | :1348-1381 |
| Supply | T/T/F/F/T/T/T/T/F/F/F | LARGE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/5/0 | :1409-1442 |
| Takeoff | T/F/T/T/F/F/F/F/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1470-1507 |
| Takeoff Holding | T/F/T/T/F/F/F/F/F/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1535-1572 |
| Transfer (FW) | T/T/F/F/F/T/T/T/T/F/F | LARGE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1600-1633 |
| Transfer (Heli) | T/T/F/F/T/T/T/T/T/F/F | SMALL | NONE | 0 | 100 | 100 | 500 | 0/0/0/0/0/0 | :1660-1692 |
| Troop Insertion | T/T/F/F/T/T/T/T/T/F/F | SMALL | STILL | 0 | 100 | 100 | 0 | 0/0/0/0/0/8 | :1719-1751 |
| Troop Mvmt (Ins/Capt) | T/F/F/F/F/F/F/T/T/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1778-1810 |
| Troop Mvmt (Ins/Def) | T/F/F/F/F/F/F/T/T/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1837-1869 |
| Troop Mvmt (Patrol) | F/T/F/F/F/T/F/T/T/F/F | NONE | NONE | 0 | 100 | 100 | 0 | 0/0/0/0/0/0 | :1896-1928 |

All route colours are COLOUR_WHITE except Engage = COLOUR_RED (eech ts_dbase.c:669).

### 2.6 Waypoint sub-types — 37 types (eech `entity/system/en_types/en_sbtyp.h:596-637`)

APPROACH, ATTACK, CAP_LOOP, CAP_START, CONVOY, DEFEND, DROP_OFF, END, ESCORT, FINISH_DROP_OFF, HOLDING, HOLDING_LOOP, IMPOSSIBLE, LAND, LANDED, LIFT_OFF, LOWER_UNDERCARRIAGE, NAVIGATION, PREPARE_FOR_DROP_OFF, PICK_UP, RAISE_UNDERCARRIAGE, RECON, REPAIR, REVERSE_CONVOY, START_UP, SUB_ROUTE_NAVIGATION, TAKEN_OFF, TARGET, TAXI, TOUCH_DOWN, TROOP_CAPTURE, TROOP_DEFEND, TROOP_INSERT, TROOP_PICKUP_POINT_END, TROOP_PICKUP_POINT_START, TROOP_PUTDOWN_POINT, WAIT, PREPARE_FOR_INSERTION.

`waypoint_data` struct (eech `entity/special/waypoint/wp_dbase.h:67-152`): name, verbose op state, `mobile_follow_waypoint_offset`, `waypoint_action_message`, `waypoint_reached_message`, `waypoint_reached_return_value`, `planner_moveable`, `objective_waypoint`, `player_skip_waypoint`, `check_waypoint_action`, `guide_sub_type`, map icon, then per mobile class (FW / HC / ground / sea): minimum-previous-waypoint distance, action radius, reached radius, velocity, last-to-reach flag, transmit-recon flag, position type, movement type.

### 2.7 Landing entity struct (eech `entity/special/landing/landing.h:77-112`)

`sub_type` (one of the 6 landing types), `position`, list roots `task_dependent_root, assigned_task_root, takeoff_queue_root`, `route_node`, slot counters `reserved_landing_sites, free_landing_sites, total_landing_sites`, and bitmask locks `inside_hangar, landing_lock, landed_lock, takeoff_lock`. At creation `free = total`, `reserved = 0` (eech ld_creat.c:137-163).

### 2.8 Route-generation biasing table (eech `ai/taskgen/croute.c:113-166`)

| Movement type | elevation_bias | range_bias | side_bias | min_route_range | route_deviation_size | num_route_samples | optimise_tolerance |
|---|---|---|---|---|---|---|---|
| NONE | 1.0 | 1.0 | 1.0 | 5000.0 | 3.0 | 8.0 | 0.94 |
| AIR | 5.0 | 0.5 | 1.0 | 5000.0 | 3.0 | 8.0 | 0.94 |
| GROUND | 1.0 | 1.0 | 1.0 | 5000.0 | 3.0 | 8.0 | 0.94 |
| SEA | 9999.0 | 0.1 | 1.0 | 5000.0 | 2.0 | 6.0 | 0.94 |
| ALL | 1.0 | 1.0 | 1.0 | 5000.0 | 3.0 | 8.0 | 0.94 |

### 2.9 Misc defines

| Name | Value | Source |
|---|---|---|
| TASK_ASSIGN_NO_MEMBERS | 0 | eech ai/taskgen/taskgen.h:79 |
| TASK_ASSIGN_ALL_MEMBERS | 0xffffffff | eech ai/taskgen/taskgen.h:80 |
| KEYSITE_TASK_ASSIGN_TIMER | 3.0 * ONE_MINUTE | eech entity/special/keysite/keysite.h:69 |
| MAX_TROOP_ROUTE_COUNT | 16 | eech ai/taskgen/taskgen.c:91 |
| TASK_SAFE_LIMIT | 0 (dead — used only in `#if 0` body) | eech ai/taskgen/taskgen.c:89 |
| terminator_point | {-1,-1,-1} vararg route terminator | eech ai/taskgen/taskgen.c:97-98 |

## 3. Features

### TASK-F1 — Task entity creation (`create_task`)

Server-only variadic constructor (eech taskgen.c:114-439). Behavior:
1. `validate_task_generation` gate — **always returns TRUE**; the real per-force check is `#if 0` dead code (eech taskgen.c:2373-2433).
2. Increments `force.task_generation[sub_type].created` counter (taskgen.c:209).
3. Reads varargs as quads `(position, dependent, waypoint_type, formation_type)` until `terminator_point`; NULL positions skipped (so CAP creators can pass optional waypoints) (taskgen.c:219-271). Positions are `ceil()`ed (taskgen.c:239-241). Route arrays heap-copied; `route_length` excludes the terminator (taskgen.c:281-295).
4. Task id = created-count wrapped to `NUM_TASK_ID_BITS` (taskgen.c:303-310).
5. Creates the entity with sub_type, id, `FLOAT_TYPE_EXPIRE_TIMER = expire_timer`, priority, critical flag, movement type, route length, side, and parent `LIST_TYPE_TASK_DEPENDENT = task_objective` (taskgen.c:325-339). Stop timer set only if > 0 (taskgen.c:351-354). Route pointers + `PTR_TYPE_RETURN_KEYSITE = end_keysite` set and transmitted (taskgen.c:362-368).
6. **Primary tasks only** are linked to `start_keysite`'s LIST_TYPE_UNASSIGNED_TASK (taskgen.c:376-381); non-primary tasks (ENGAGE, troop movement) never sit on a keysite list.
7. `INT_TYPE_TASK_DIFFICULTY` computed via `assess_task_difficulty` (taskgen.c:383).
8. If the objective is enemy-side, the enemy force receives `ENTITY_MESSAGE_TASK_CREATED` (taskgen.c:391-408) — feeds enemy reaction generation.
9. Task inserted into the sector task list of the objective's (or last route node's) sector (taskgen.c:416-436).

Entity defaults at raw creation: state = UNASSIGNED, terminated = IN_PROGRESS, side = UNINITIALISED (eech ts_creat.c:128-134).

### TASK-F2 — Task states and list membership

Three states mirrored 1:1 to list membership. `get_local_task_list_type`: UNASSIGNED→LIST_TYPE_UNASSIGNED_TASK, ASSIGNED→LIST_TYPE_ASSIGNED_TASK, COMPLETED→LIST_TYPE_COMPLETED_TASK (eech task.c:561-589). State changes are driven by *re-parenting*: the task's `response_to_link_parent` sets `INT_TYPE_TASK_STATE` from the list it just joined and (for primary tasks) notifies the campaign screen with MISSION_CREATED / MISSION_ASSIGNED / MISSION_COMPLETED (eech ts_msgs.c:115-181).

### TASK-F3 — Timer update loop (server) & expiry

Per-frame `update_server` on every task (eech ts_updt.c:79-201):
- **UNASSIGNED**: if `expire_timer > 0`, decrement by delta time; on reaching 0 send self `ENTITY_MESSAGE_TASK_TERMINATED (TASK_TERMINATED_EXPIRE_TIME_REACHED)` (ts_updt.c:99-124). Zero expire timer = never expires.
- **ASSIGNED**: expire timer must be 0 for primary tasks (debug assert, ts_updt.c:138-141 — it is cleared at assignment, see TASK-F10). If `stop_timer > 0`, decrement; on 0 send self `ENTITY_MESSAGE_TASK_COMPLETED (TASK_TERMINATED_STOP_TIME_REACHED)` (ts_updt.c:145-161). This is how CAP/BARCAP end after their patrol duration.
- **COMPLETED**: expire timer (asserted primary-only) counts down; on 0 the task family is destroyed locally and on clients (ts_updt.c:166-199).

Completed-task lifetime default: `completed_task_expire_time = 20.0 * ONE_MINUTE` (eech task.c:81-82), settable via `set_completed_task_expire_time` (task.c:1457-1460). Client `update_client` only mirrors timer decay, no events (ts_updt.c:207-248).

| Constant | Value | Source |
|---|---|---|
| completed_task_expire_time | 20 min | eech entity/special/task/task.c:82 |

### TASK-F4 — TASK_COMPLETED message handling

`response_to_task_completed` (server; eech ts_msgs.c:261-390). Only acts if `task_completed == TASK_INCOMPLETE`:
- Primary + UNASSIGNED: mark COMPLETED_FAILURE, then TASK_TERMINATED (OBJECTIVE_MESSAGE) — e.g. objective destroyed before anyone was assigned (ts_msgs.c:295-306).
- Primary + ASSIGNED: run `assess_task_completeness`; if a verdict is reached: set `INT_TYPE_TASK_COMPLETED`, award points, notify the force (`ENTITY_MESSAGE_TASK_COMPLETED` → force stats), move the task from ASSIGNED to COMPLETED list, then notify each guide with TASK_COMPLETED (guides inform the group and return it to base) (ts_msgs.c:307-374).
- Non-primary: mark FAILURE and terminate immediately (ts_msgs.c:377-386).

### TASK-F5 — TASK_TERMINATED message handling

`response_to_task_terminated` (server; eech ts_msgs.c:396-521):
1. Persistent tasks (Landing/Takeoff/holding) must never be terminated — debug assert, returns FALSE (ts_msgs.c:421-431).
2. Cyclic guard: ignore if `task_terminated != IN_PROGRESS` already (ts_msgs.c:437-440).
3. Records the terminated reason, then runs the COMPLETED path too if still incomplete (ts_msgs.c:453-462).
4. All task dependents (children on LIST_TYPE_TASK_DEPENDENT, except the sender) get TASK_COMPLETED (ts_msgs.c:468-480) — e.g. a troop-movement child completing when its parent insertion task dies.
5. Each guide gets TASK_TERMINATED in a drain loop, severing task↔guide↔group↔member links (ts_msgs.c:488-497).
6. Disposal: if state ≠ UNASSIGNED and the type is *visible*, `kill_client_server_entity` (keeps the debriefable corpse); otherwise the entity family is destroyed outright (ts_msgs.c:499-518).

### TASK-F6 — Completion assessment per type (`assess_task_completeness`)

Server-only, primary tasks only; computes `rating` 0..1 and a completed verdict, stores rating in FLOAT_TYPE_RATING (eech task.c:94-502). Thresholds come from db `task_pass_percentage_partial/success` ÷ 100 (task.c:138-140). Per type:

| Task type(s) | Rule | Source (task.c) |
|---|---|---|
| ADVANCE, COASTAL_PATROL, FREE_FLIGHT, RETREAT, TRANSFER_FW, TRANSFER_HELI | SUCCESS (rating 1.0) iff terminated = WAYPOINT_ROUTE_COMPLETE; IN_PROGRESS → incomplete; anything else FAILURE | :153-181 |
| BARCAP, CAP | SUCCESS iff STOP_TIME_REACHED; else as above | :183-205 |
| ESCORT | On OBJECTIVE_MESSAGE: rating = surviving fraction of escorted group (baseline member count stored in task_user_data); rating ≥ partial → SUCCESS else FAILURE | :207-256 |
| BAI, CAS, SEAD | rating = fraction of objective group destroyed vs baseline; if baseline ≤ 4 members, only total destruction passes (rating forced 0 while any survive); rating ≥ success → SUCCESS, ≥ partial → PARTIAL, else incomplete while IN_PROGRESS, FAILURE once terminated; group wiped out → SUCCESS rating 1.0 | :258-345 |
| GROUND_STRIKE, ANTI_SHIP_STRIKE | Objective is a keysite. Success if keysite not in use or efficiency < 0.8 × its minimum efficiency (the ×0.8 stops "safe by repairing one structure", :360-364); else rating = baseline efficiency (task_user_data) − current efficiency, thresholds as usual; WAYPOINT_ROUTE_COMPLETE with insufficient rating → PARTIAL (:410-417) | :347-430 |
| BDA, RECON, REPAIR, SUPPLY, TROOP_INSERTION | SUCCESS iff OBJECTIVE_MESSAGE; else FAILURE when terminated | :432-459 |
| OCA_STRIKE, OCA_SWEEP, TROOP_MOVEMENT_* | SUCCESS iff WAYPOINT_ROUTE_COMPLETE or OBJECTIVE_MESSAGE; else FAILURE when terminated | :461-482 |
| other | `debug_fatal` unknown task type | :484-489 |

### TASK-F7 — Points award

`award_points_for_task_completion` (eech task.c:508-555): FAILURE → 0 pts; PARTIAL → `points >> 2` (quarter, integer); SUCCESS → full `INT_TYPE_POINTS_VALUE`; added into `INT_TYPE_TASK_SCORE`.

### TASK-F8 — Per-creator expiry, stop time and specified-route patterns (taskgen.c)

Each `create_*_task` fixes the unassigned-expiry window, stop timer, and the typed waypoint skeleton passed to `create_task` (routing then in-fills navigation waypoints, TASK-F16):

| Creator | Expire (unassigned) | Stop timer | Specified route (waypoint types) | Source (taskgen.c) |
|---|---|---|---|---|
| create_anti_ship_strike_task | 30 min | 0 | ATTACK @ target | :485, :498 |
| create_bai_task | 20 min | 0 | ATTACK @ target group | :562, :575 |
| create_barcap_task | 10 min | `duration` param | CAP_START, NAV, NAV, CAP_LOOP (4-corner patrol box) | :690, :700-706 |
| create_bda_task | 30 min | 0 | RECON @ objective | :761, :774 |
| create_cap_task | 10 min | `duration` param | CAP_START, NAV, NAV, CAP_LOOP | :877, :887-893 |
| create_close_air_support_task | 20 min | 0 | ATTACK @ target group | :945, :958 |
| create_coastal_patrol_task | 30 min | 0 | NAV @ source, END @ destination | :1014, :1027-1028 |
| create_escort_task | 15 min | 0 | single ESCORT waypoint, dependent = escorted group | :1065, :1101 |
| create_ground_force_task (ADVANCE/RETREAT) | 12 h | 0 | CONVOY, SUB_ROUTE_NAVIGATION, REVERSE_CONVOY, DEFEND | :1184, :1211-1214 |
| create_ground_strike_task | 40 min | 0 | ATTACK @ keysite | :1271, :1284 |
| create_oca_strike_task | 30 min | 0 | ATTACK | :1347, :1360 |
| create_oca_sweep_task | 30 min | 0 | ATTACK | :1411, :1424 |
| create_recon_task | 10 min | 0 | RECON | :1477, :1490 |
| create_repair_task | 30 min | 0 | NAV, REPAIR | :1530, :1543-1544 |
| create_sead_task | 30 min | 0 | ATTACK | :1597, :1610 |
| create_supply_task | 20 min | 0 | PICK_UP @ supplier, PREPARE_FOR_DROP_OFF, DROP_OFF @ requester, FINISH_DROP_OFF | :1696, :1709-1712 |
| create_transfer_task | 10 min | 0 | NAV @ destination keysite | :1776, :1789 |
| create_troop_insertion_task | 45 min | 0 | NAV (in air), PREPARE_FOR_INSERTION, TROOP_INSERT, WAIT, NAV (out) | :1885, :1898-1902 |
| create_troop_movement_capture_task | 0 (never) | 0 | 16 nodes: NAV… then TROOP_PUTDOWN_POINT, final TROOP_CAPTURE at keysite (±5 m jitter), FORMATION_INFANTRY_COLUMN | :2017-2044, :1981-1999 |
| create_troop_movement_defend_task | 0 (never) | 0 | NAV, TROOP_PUTDOWN_POINT, NAV, TROOP_DEFEND | :2065-2080 |
| create_troop_movement_patrol_task | 0 (never) | 0 | up to 16 TAXI nodes from 3D-model patrol route, else 6 auto nodes on a circle of radius ×(0.8..1.0), last node TROOP_DEFEND | :2103-2204 |
| create_user_task (player FREE_FLIGHT etc.) | 3 min | 0 | stop waypoint per type: RECON / ATTACK / END / IMPOSSIBLE | :2261-2315 |

ENGAGE (see TASK-F18) is created in engage.c, not taskgen.c.

### TASK-F9 — Keysite assignment cadence

Keysite server update decrements `assign_timer`; at ≤ 0 and if in use, runs `assign_keysite_tasks` once per category RECON, STRIKE, SUPPORT (MISC is never batch-assigned) and resets the timer to `KEYSITE_TASK_ASSIGN_TIMER` = 3 min — doubled to 6 min if the keysite is not currently usable (eech ks_updt.c:107-124). Initial timer is randomized `frand1() * 3 min` to stagger keysites (eech ks_creat.c:166). An out-of-band forced pass happens when a keysite under air attack creates a defensive CAP (eech keysite.c:903-922, assist-timer gated; CAP created with priority 10.0, duration 15 min, critical=TRUE at keysite.c:915).

### TASK-F10 — assign_keysite_tasks: sorting, player reserve, assignment budget

Per keysite & category (eech assign.c:96-300):
1. Bail if no unassigned tasks of this category (assign.c:140-157).
2. Count idle groups per group type across the force's **air registry** (assign.c:163-177) — used for minimum-idle-count reserve (TASK-F11).
3. Sort matching tasks by `FLOAT_TYPE_TASK_PRIORITY`, with **critical tasks doubled** (`sort_order *= 2.0`, assign.c:201-204), via `quicksort_entity_list` (assign.c:212).
4. Assignment budget: `assign_count = max(keysite_database[type].assign_task_count, 1)` per pass; `non_critical_task_count = keysite_database[type].reserve_task_count` (assign.c:218-220; both are 2-bit DATA-DRIVEN keysite db fields, eech entity/special/keysite/ks_dbase.h:94-95, loadable via gwutcfg.c:1496-1497).
5. Per task, in sorted order: skip if player-locked (LIST_TYPE_PILOT_LOCK parent, assign.c:235-238); **reserve for player**: a non-critical task whose expire timer still exceeds 3 min (KEYSITE_TASK_ASSIGN_TIMER) is skipped while the reserve budget lasts (assign.c:244-255) — i.e. the AI leaves fresh, non-critical missions on the board for one or more cycles so a human can take them.
6. `get_suitable_registered_group` then `assign_primary_task_to_group`; each success decrements the budget (assign.c:257-295).
7. **No group found** → nothing happens; the task remains on the unassigned list and is retried every cycle until it expires (TASK-F3) → TERMINATED(EXPIRE_TIME_REACHED) → FAILURE.

### TASK-F11 — Group search (`get_suitable_registered_group`)

Iterates the task's keysite's LIST_TYPE_KEYSITE_GROUP children in list order (eech assign.c:401-518). Filter chain, in order:
1. group not player-locked (assign.c:445);
2. not an ASSAULT_SHIP (carriers never get tasks; assign.c:451-457);
3. `GROUP_MODE_IDLE` (assign.c:459);
4. group `sleep == 0` (assign.c:461);
5. same side as task (assign.c:463);
6. force-wide idle count of this group type must exceed `group_database[type].minimum_idle_count` (a per-group-type reserve; assign.c:465-474);
7. member count ≥ task's `INT_TYPE_MINIMUM_MEMBER_COUNT` (assign.c:476);
8. all members awake (`FLOAT_TYPE_SLEEP == 0`; assign.c:478, helper 1282-1303);
9. suitability `get_group_to_task_suitability(group_type, task_type) > 0` (assign.c:480-482);
10. task-specific checks (TASK-F12);
11. locality: group could reach the task in time (TASK-F13).

Winner: the group with the **lowest positive suitability value** (`result < best_result`, best_result starts FLT_MAX; assign.c:433-501) — i.e. the *least over-qualified* capable group is preferred, conserving strong groups. Distance is a pass/fail gate only, not a tiebreaker.

### TASK-F12 — Suitability matrix (`ai/highlevl/suitable.c`)

Precomputed `group_task_array[group_type][task_type]` at init (suitable.c:223-263). `calculate_group_to_task_suitability` (suitable.c:88-206):
- **Critical (0.0 = unsuitable)**: movement type must match unless task is MOVEMENT_TYPE_ALL (:115-118); group's default landing type must be within task's `landing_types` mask (:120-125); group ai_stats must meet-or-exceed task ai_stats in movement_speed, movement_stealth, cargo_space, troop_space, ground_attack_strength, air_attack_strength (:129-167); if task `engage_enemy`, group must have `default_engage_enemy` (:171-177).
- **Graded**: result = 1.0, multiplied by `min(group_AA / task_AA, 1)` and `min(group_GA / task_GA, 1)` when the task demands those stats (:183-205). Result ∈ [0,1].

### TASK-F13 — Task-specific suitability checks (`suitable_group_task_specific_checks`)

eech assign.c:306-395:
- **ESCORT**: speed-class matching on `group_database[...].ai_stats.movement_speed` — fast objective (≥5) requires fast escort; slow objective forbids fast escort and (magitek mod) any escort slower than the objective (:318-364).
- **TROOP_INSERTION**: assaults against an enemy AIRBASE keysite require group member count ≥ 2 (:366-391).

### TASK-F14 — Locality gates

- Group→task: `assess_group_task_locality_factor` — ETA from the first member's position to the task's keysite (or start position) at cruise speed; reject if `eta > task expire_timer` (eech group.c:245-315+).
- Generic entity→task variant `assess_task_locality_factor`: reject if `cruise_speed × expire_timer < straight-line distance` to VEC3D_TYPE_START_POSITION (eech task.c:664-702).

### TASK-F15 — Primary-task assignment side effects (`assign_primary_task_to_group`)

eech assign.c:524-653. On successful `assign_task_to_group`:
1. Reset group to its default formation (:559-564).
2. If the group lives on a keysite list and the task has a RETURN_KEYSITE, re-parent the group to that keysite now (:570-580) — transfers/strikes relocate the group's home base at assignment time.
3. Notify force `ENTITY_MESSAGE_TASK_ASSIGNED` (:586-592).
4. **Escort spawning**: if db `escort_required_threshold != ESCORT_NEVER(15)`, compute `threat = assess_task_difficulty(...)` (TASK-F17); if `threat >= threshold`, `create_escort_task(group, critical = threat >= ESCORT_CRITICAL(6), priority = escort db priority 7, ...)` (:598-627).
5. Store `FLOAT_TYPE_START_TIME` = session elapsed time (:633).
6. **Clear the expire timer to 0** (it is reused for the completed-task destroy countdown) (:639).

### TASK-F16 — assign_task_to_group / guide-stack mechanics / route hookup

`assign_task_to_group` (eech assign.c:765-951):
- Rejects empty groups; ASSAULT_SHIP groups may only take ENGAGE tasks (:804-815); LANDING/TAKEOFF(±HOLDING) types are illegal here (debug_fatal; :821-836).
- If db `assess_landing` (INT_TYPE_ASSESS_LANDING): resolve the end keysite = task RETURN_KEYSITE; if it differs from the start keysite it must have `get_keysite_landing_sites_available(end, group default landing type) >= member count` else **assignment fails** (:861-888). If no return keysite: fall back to the start keysite; if the group has no keysite (independent), find the closest friendly keysite within 1 km search granularity and require free sites (:889-920). The chosen keysite is written back to PTR_TYPE_RETURN_KEYSITE (:919).
- `create_generic_waypoint_route(...)` (TASK-F20); on failure the assignment fails (:927-950).
- On success: `push_task_onto_group_task_stack` creates the guide entity (`create_client_server_guide_entity(task, NULL, valid_members)`), attaches the group, and if the task was UNASSIGNED moves it keysite-list UNASSIGNED→ASSIGNED (with comms SWITCH_LIST) (:659-759). Debug builds fatal if the same member would get the same task twice on the stack (:680-724).
- `assign_task_to_group_members`: for each member whose bit is in `valid_members`, attach to guide, notify member TASK_ASSIGNED; helicopters get troops loaded and fuel computed (TASK-F26) (:957-991).

Member reassignment when a task ends (`reassign_group_members_to_valid_tasks`, :997-1096): first try engage tasks (if `engage_enemy`), then walk the guide stack top-down and give each member the first in-progress task whose guide `valid_members` includes it. `assign_new_task_to_group_member` (:1102-1200): no-op if already on it; if currently on an ENGAGE task, destroy that member's guide clone first (:1151-1167); note the member may end up on a different task than requested (e.g. must TAKEOFF first, :1184).

Player interaction: `respond_to_player_task_assign_request` grants a task to the player's group only if the task has no guides yet and the group has no primary task (:1206-1241).

### TASK-F17 — Task difficulty assessment (`assess_task_difficulty`)

eech task.c:708-910. Walks the task's `route_nodes` (starting at the assigned keysite if any), traversing every map sector along each leg with Bresenham (:791-868). Per sector (`assess_task_sector_difficulty`, :916-941): +1 `air_threats` if the sector has any enemy surface-to-air defence level > 0; +1 `enemy_sectors` if sector side ≠ task side. Total difficulty = `min(air_threats >> 1, 5) + min(enemy_sectors >> 1, 5)` (:890-907), i.e. 0..10, one point per 2 enemy-SAM sectors and per 2 enemy sectors. NOTE: `task_level = task_database[..].difficulty_rating` is loaded (:756) but **not added to the returned total** — the header comment (:711-725) describes a 0..100 ten-factor scheme that was never implemented. Used for escort decisions (TASK-F15) and INT_TYPE_TASK_DIFFICULTY (TASK-F1).

### TASK-F18 — Engage task creation (`create_engage_task`)

eech engage.c:88-188. Preconditions: group `INT_TYPE_ENGAGE_ENEMY` set (:111), objective identifies as aircraft/vehicle/fixed/weapon (:124-127), session `SUPPRESS_AI_FIRE` off (:129-132). Expiry:

| Case | Expire time | Source |
|---|---|---|
| `expire == TRUE` (opportunistic) | 2 min + frand1()·1 min | eech engage.c:140 |
| `expire == FALSE` (deliberate) | 10 min + frand1()·2.5 min ("stops attackers hanging around target area too long") | eech engage.c:148 |

Creates `ENTITY_SUB_TYPE_TASK_ENGAGE` via `create_task` with priority = engage db priority 10, critical=TRUE, no stop timer, objective = target, and a single `ENTITY_SUB_TYPE_WAYPOINT_TARGET` waypoint at the target position (:165-177). Engage tasks are non-primary, solo, invisible; created with `TASK_ASSIGN_NO_MEMBERS` (guide has no members yet) then distributed by TASK-F19.

### TASK-F19 — Engagement rules: target scans and member/target allocation

Scan helpers (all create one engage task per qualifying enemy, then call the allocator):
- `engage_targets_in_sector(group, sx, sz, task_target_type, expire)` — every entity in the sector whose `INT_TYPE_TASK_TARGET_TYPE` intersects the requested target-type mask, alive, enemy side, valid target type (eech engage.c:194-264).
- `engage_targets_in_area(group, centre, radius, mask, expire)` — same over all sectors overlapping the circle, with exact range ≤ radius check (engage.c:270-391).
- `engage_targets_in_group(group, target_group, expire)` — one engage task per living member of the target group; aborts if an engage task already exists against any member of it (vehicle targets exempted from the abort) (engage.c:515-625).
- `engage_specific_target(group, target, valid_members, expire)` — reuses an existing engage task against that exact target if present (engage.c:631-707); `engage_specific_targets` is the wingman "attack my targets" path, AI-only (engage.c:713-740).

Allocator `assign_engage_tasks_to_group(group, valid_members)` (engage.c:796-1192):
1. Collect the group's guide-stack entries with `INT_TYPE_VALID_GUIDE_MEMBERS == 0` (unclaimed engage guides), in-progress, target alive with damage level > 0 (:839-866). Dead-target guides are skipped (a terminate here crashed — thealx comment, dead code :953-963).
2. Priority per task = target's `FLOAT_TYPE_TARGET_PRIORITY_AIR_ATTACK` (aircraft groups) or `_GROUND_ATTACK` (:972-979), **plus** proximity bonus `max(0, 0.1 − 0.1·d²/MAX_ENGAGE_RANGE)` (:981), **±0.1** if the target is a human player on HARD/EASY difficulty (:983-995). Sorted by priority (:1016).
3. `assigned_count` per task = number of entities already targeting that victim (LIST_TYPE_TARGET pursuers, :1037-1053).
4. Per AI member (players never auto-assigned, :1072; member must have ENGAGE_ENEMY, :1074): choose the least-pursued task ("one member per task, team-up when tasks run out", :1055-1062) that isn't the member itself (:1107-1114), is within `MAX_ENGAGE_RANGE = (16 km)²` for non-aircraft (aircraft use weapon-selection criteria instead, :1082-1132), and for which `get_best_weapon_for_target` ≠ NO_WEAPON (:1138). Assignment goes through `assign_new_task_to_group_member` (:1154).
5. Returns the bitmask of members left unassigned.

| Constant | Value | Source |
|---|---|---|
| MAX_ENGAGE_RANGE | (16.0 km)² (squared metres) | eech engage.c:794 |
| engage priority proximity bonus | +0.1 → 0 linear over 16 km | eech engage.c:981 |
| player difficulty priority tweak | +0.1 HARD / −0.1 EASY | eech engage.c:991-994 |

Teardown: `terminate_all_engage_tasks(group)` aborts every unclaimed engage guide (TASK_TERMINATED_ABORTED; engage.c:1198-1232) — invoked e.g. when a group reaches its LAND waypoint (mb_msgs.c:1207). `terminate_entity_current_engage_task` drops one member's engage guide (engage.c:1238-1259).

### TASK-F20 — Generic waypoint-route construction (`create_generic_waypoint_route`)

eech croute.c:200-827. Runs on server and (with transmitted parameters) on clients. Steps:
1. No-op TRUE if the task already has waypoints (:277-292).
2. Movement type / route entity type / landing type from the **group's** database; `generate_route` = task db `task_route_search`; `start_point_count` = task db `add_start_waypoint` (:310-328).
3. Build the linked "specified route" from the task's route arrays (positions `ceil`ed, dependent/type/formation preserved) (:336-377).
4. If `add_start_waypoint`: prepend a NAVIGATION waypoint at the first member's current position (client: transmitted start), FORMATION_ROW_LEFT (:402-455); if a return keysite exists, append an `ENTITY_SUB_TYPE_WAYPOINT_LAND` waypoint at its position with the keysite as dependent (:457-522).
5. If `task_route_search`: `generate_biased_vec3d_route` (TASK-F21) replaces the straight legs with terrain-aware polylines; on failure the whole assignment fails (:531-559).
6. Route checksum = 8-bit sum of interior node coordinates (endpoints excluded because of pack/unpack drift, :1056-1058); server stores INT_TYPE_ROUTE_CHECK_SUM, clients only log a warning on mismatch (:574-603).
7. Create one WAYPOINT entity per route node, parented to the task's LIST_TYPE_WAYPOINT, with position bounded to the map, sub_type NAVIGATION, closest road node (5 km), altitude = member cruise altitude, `FLOAT_TYPE_FLIGHT_TIME` = leg distance / cruise velocity (:611-693). Nodes whose x/z match a specified node inherit that node's type, formation, `INT_TYPE_POSITION_TYPE` (from waypoint db per route entity type) and get linked as LIST_TYPE_TASK_DEPENDENT child of the node's dependent entity (:699-729).
8. `parser_task_waypoint_route` post-pass enforces `minimum_previous_waypoint_distance` (waypoint db, per mobile type): NAVIGATION waypoints that crowd the next waypoint are slid to the midpoint or pushed back to exactly min-range (:833-1034).
9. Server transmits `ENTITY_COMMS_CREATE_WAYPOINT_ROUTE` so clients rebuild the identical route (:820-824).

`temp_create_generic_waypoint_route` (croute.c:1696-2044) is a group-less variant (fixed 50 m height/velocity, helicopter landing type) used for preview/planning — returns raw route nodes without creating waypoint entities.

### TASK-F21 — Biased route generation (recursive midpoint search)

eech croute.c:1132-1236 (`generate_biased_vec3d_route`) per specified leg: `create_route` makes start/end nodes then `generate_best_mid_point` recursively bisects (:1242-1309). `get_best_point` (:1315-1458): only splits legs longer than `min_route_range` (5 km); samples `num_route_samples` (8; sea 6) points along the perpendicular through the leg midpoint, spread = leg length / deviation size (3; sea 2); rating per sample (`get_route_point_rating`, :1502-1553):

```
avg_elev  = 3-sample smoothed terrain elevation, clamped ≥ 0          eech croute.c:1520-1526
elevation = elevation_bias * avg_elev                                  eech croute.c:1528
range_bias= range_bias_db * |2*sample - N| / (2N)   (centre preferred) eech croute.c:1530-1532
side_bias = side_bias_db * (sector side != own side)                   eech croute.c:1534-1538
rating    = elevation + range_bias*max(avg_elev,1) + side_bias*max(avg_elev,1)   croute.c:1540-1542
```

Lowest rating wins → air routes hug valleys (elevation_bias 5), sea routes shun any elevation (9999), all avoid enemy sectors. `second_past_route` re-optimises each interior node against its new neighbours (:1464-1496); `optimise_route` deletes nodes where adjacent legs are within `optimise_tolerance` (|cos| > 0.94, ≈ ±20°) or zero-length (:1559-1669).

### TASK-F22 — Waypoint semantics (types → guide behavior → task events)

Waypoint db per type (name, action/reached message, guide sub type — eech wp_dbase.c, cited lines): APPROACH :86-96, ATTACK :140-150 (action msg WAYPOINT_ATTACK_ACTION), CAP_LOOP :194-204, CAP_START :248-258, CONVOY :302-312, DEFEND :356-366, DROP_OFF :410-420, END :464-474, ESCORT :518-528 (no messages; guide NAVIGATION_VIRTUAL — escort formates on a *virtual* point tracking the dependent group), FINISH_DROP_OFF :572-582, HOLDING :626-636, HOLDING_LOOP :680-690, IMPOSSIBLE :734-744 (no messages), LAND :788-798, LANDED :842-852 (guide GUIDE_LANDED), LIFT_OFF :896-906 (guide LANDING_DIRECT), LOWER_UNDERCARRIAGE :950-960 (action msg), NAVIGATION :1004-1014, PREPARE_FOR_DROP_OFF :1058-1068, PICK_UP :1112-1122, RAISE_UNDERCARRIAGE :1166-1176, RECON :1220-1230 (both action & reached msgs), REPAIR :1274-1284, REVERSE_CONVOY :1328-1338 (guide NAVIGATION_ROUTED — road network following), START_UP :1382-1392 (guide LANDING_DIRECT), SUB_ROUTE_NAVIGATION :1436-1446, TAKEN_OFF :1490-1500, TARGET :1544-1554 (reached msg = WAYPOINT_END_REACHED), TAXI :1598-1608 (guide LANDING_DIRECT), TOUCH_DOWN :1652-1662, TROOP_CAPTURE :1706-1716, TROOP_DEFEND :1760-1770, TROOP_INSERT :1814-1824 (guide NAVIGATION_ALTITUDE), TROOP_PICKUP_POINT_END :1868-1878, TROOP_PICKUP_POINT_START :1922-1932, TROOP_PUTDOWN_POINT :1976-1986, WAIT :2030-2040, PREPARE_FOR_INSERTION :2084-2094.

Guide navigation sub-types (eech en_sbtyp.h:348-355): NAVIGATION_DIRECT (fly straight to point), NAVIGATION_VIRTUAL (point tracks another entity — escort), NAVIGATION_ROUTED (follow road/sea network nodes), NAVIGATION_ALTITUDE (altitude-critical approach — troop ops), LANDING_DIRECT, LANDED.

Campaign-relevant reached-handlers in `entity/mobile/mb_msgs.c`:
- **DEFEND reached** → task gets TASK_TERMINATED(WAYPOINT_ROUTE_COMPLETE); group ENGAGE_ENEMY restored to default; members stopped (mb_msgs.c:779-859).
- **LAND reached** → task TERMINATED(WAYPOINT_ROUTE_COMPLETE); if keysite in use & friendly: LANDING_SITE_REQUEST to the landing entity, all engage tasks terminated, ENGAGE_ENEMY off, group re-parented to the keysite (mb_msgs.c:1150-1235); if the keysite was lost: emergency transfer task to a new keysite (mb_msgs.c:1251-1269).
- Other route-complete emitters at mb_msgs.c:828, 1255, 2320, 2350 and gunship dynamics.c:2021 (player landing).

### TASK-F23 — Landing-site slot & parking allocation

State per LANDING entity (one per landing type per keysite): `total/free/reserved_landing_sites` + bitmask locks (Data model 2.7). Message protocol (all server-side, eech ld_msgs.c):
- **RESERVE_LANDING_SITE(count)**: `reserved += count` (assert ≤ total) (:950-1058). **UNRESERVE**: `reserved -= count` at :1880+ (symmetric; invoked per member when the landing request is processed, :243).
- **Availability** for assignment = `free − reserved` (`get_keysite_landing_sites_available`, eech keysite.c:313-331; consumed by assign.c:879/:906 and highlevl.c:2317/:2537).
- **LANDING_SITE_REQUEST** (group arrives overhead; :176-470): per member — unreserve 1; formation position = first clear bit in `landed_lock` (:249-263); if the landing-route slot for that formation position is locked (`landing_lock` bit; FIXED_WING_TRANSPORT also blocked while the FW runway route is locked :285-298) the member is placed on the **LANDING_HOLDING task** with a fresh guide and the site is locked for it (:300-373); otherwise it is placed on the **LANDING task** guide, and both LOCK_LANDING_ROUTE and LOCK_LANDING_SITE are applied (:375-460). ATC speech hooks at both branches.
- **LOCK_LANDING_SITE**: `landed_lock |= bit(formation_position)`, `free--` (assert ≥ 0) (:599-711). **UNLOCK_LANDING_SITE**: `free++` (assert ≤ total) (:1567-1638+).
- **LOCK_TAKEOFF_ROUTE**: takeoff slot = formation position modulo the taken-off waypoint's formation size; grant iff the `takeoff_lock` bit is clear (else FALSE + "await takeoff clearance" ATC speech); also opens hangar doors within range (door timer 30 s) (:717-944). UNLOCK at :1689+. TAKEN_OFF waypoint reached handler at :1991+.
- Landing/holding/takeoff routes themselves are persistent solo tasks (LANDING, LANDING_HOLDING, TAKEOFF, TAKEOFF_HOLDING) owned by the landing entity: `get_local_landing_entity_task(landing_en, type)` (used at :226-228); keysite landing position = first waypoint of the LANDING task route (keysite.c:300-304).
- `response_to_task_terminated` on the landing entity (:1120) handles cleanup when a member's landing task ends. LIST_TYPE_TAKEOFF_QUEUE orders members awaiting departure (landing.h:89; manipulated in events/ev_debug.c:1637-1656 and mobile code).

### TASK-F24 — Keysite selection for new tasks (`find_most_suitable_keysite_for_task`)

Used by order generation to pick a task's start keysite (eech task.c:1030-1278). Candidate filter: keysite in use, has resident groups, supports one of the task's landing types (ground tasks exempt from landing-type check, :1099), and (if `check_capacity`) keysite db `air_force_capacity >= task db keysite_air_force_capacity` (:1103). Score:

| Term | Formula | Source (task.c) |
|---|---|---|
| Group availability | +5.0 per idle suitable alive group (KEYSITE_TASK_IDLE_GROUP_COUNT_BIAS), +0.5 per busy one (BUSY_BIAS); skipped (score = 12.0 max) when `!check_capacity`; capped at 12.0 (MAX_GROUP_COUNT_BIAS); score 0 → skip keysite | :1020-1163 |
| Range falloff | reject if range ≥ 100 km (MAX_RANGE_BIAS); else `x = range/max − 1`; `score *= 2·x⁴` | :1026, :1179-1188 |
| Task saturation | ×`max(1 − 0.2·(unassigned tasks of same type), 0.2)` (KEYSITE_TASK_COUNT_BIAS = 0.2) | :1028, :1200-1224 |
| Damaged keysite | ×0.5 if keysite state ≠ USABLE | :1236-1239 |

Highest score wins (:1251-1262).

### TASK-F25 — Kill/loss bookkeeping & duration estimate

`add_kill_to_task` / `add_loss_to_task` append victim/aggressor records with timestamp & day to the task's kill/loss lists and bump the `kills`/`losses` counters (eech task.c:1347-1428); consumed by debrief and `get_task_friendly_fire_incidents` (task.c:1641+). `get_task_estimated_route_duration` sums 2D leg lengths of the created waypoint route (task.c:1429-1456, twin `get_estimated_task_duration` at taskgen.c:2439-2480).

### TASK-F26 — Helicopter task preparation (troops & fuel)

On member assignment (eech assign.c:981-984): `prepare_helicopter_for_task` loads `group_database[..].ai_stats.troop_space` troops for TROOP_INSERTION (assert 0 < troops ≤ 12; assign.c:1310-1323). `set_helicopter_fuel_level` (landed AI only): estimated minutes = route duration/60; if 0 < t < 500: `t = 1.25·t + 20` margin, fuel = t × FLOAT_TYPE_FUEL_ECONOMY, level = fuel/default weight rounded **up** to quarter-tank, bounded [0.5, 1.0] (assign.c:1326-1353).

## 4. Interactions

- **Order generation (Spec 06)** calls the `create_*_task` creators and `find_most_suitable_keysite_for_task`; force `task_generation[]` counters feed its budget logic; `ENTITY_MESSAGE_TASK_CREATED` to the enemy force triggers reactions (taskgen.c:391-408).
- **Keysite system (Spec on keysites)**: assignment cadence lives in keysite update (ks_updt.c:107-124); keysite capture/destruction fails tasks via the LAND-waypoint keysite check (mb_msgs.c:1236-1269); air attacks on keysites force CAP creation + immediate assignment (keysite.c:903-938).
- **Group/guide system**: guides created per task drive actual movement; guide stack ordering determines what members do next (assign.c:1058-1089); GROUP_MODE_IDLE gates eligibility.
- **Force stats/debrief**: TASK_COMPLETED to force updates campaign statistics; `perform_debrief`, medals/promotion bits, task score and `counts_towards_player_log` feed the pilot log & debrief UI.
- **Sector system**: sector task lists (taskgen.c:436) let the UI and AI enumerate tasks spatially; sector SAM/side data drives both task difficulty (task.c:916-941) and route side-bias (croute.c:1534-1538).
- **Campaign screen/UI**: MISSION_CREATED/ASSIGNED/COMPLETED notifications (ts_msgs.c:147-173); `player_reserve_factor`, preview types and route colours are UI-facing db fields.
- **Landing system ↔ mobiles**: LAND waypoint → LANDING_SITE_REQUEST → slot/lock protocol → LANDING/LANDING_HOLDING solo tasks; takeoff mirrors it (ld_msgs.c).

## 5. Port mapping

The DCS port does **not** port the task engine: it spawns fresh DCS groups per task instead of assigning existing campaign groups, has no landing-slot arbitration, and handles expiry/completion per-module (e.g. reaction completion-on-RTB, 1800 s CAP expiry).

| Feature | Status | Note |
|---|---|---|
| TASK-F1 create_task entity | NOT PORTED | No task entities; per-module spawn calls carry equivalent parameters implicitly. |
| TASK-F2 states/lists | NOT PORTED | No unassigned/assigned/completed board; tasks are born "assigned" to a fresh spawn. |
| TASK-F3 expire/stop timers | PROXY | Per-module timers only (e.g. 1800 s CAP expiry); no unassigned-expiry concept since nothing waits for assignment. |
| TASK-F4/F5 completed/terminated messaging | NOT PORTED | Completion is per-module (e.g. reaction completes on RTB); no dependent/guide fan-out. |
| TASK-F6 per-type completion rating | NOT PORTED | No 0..1 rating, no partial/success thresholds. |
| TASK-F7 points award | UNKNOWN | Scoring module coverage not verified from this spec's sources. |
| TASK-F8 per-creator expiry/waypoint skeletons | PARTIAL | Waypoint patterns approximated by DCS mission tasks per spawned group; EECH expiry windows not carried over. |
| TASK-F9 3-min keysite assignment cadence | NOT PORTED | No assignment pass; spawning is demand-driven. |
| TASK-F10 priority sort / player reserve / budget | NOT PORTED | No task board to sort or reserve for players. |
| TASK-F11/F12/F13 group suitability matrix & checks | NOT PORTED | Fresh groups are typed to the task at spawn time; no matrix needed (fidelity gap: strong groups are never conserved). |
| TASK-F14 locality gates | NOT PORTED | Spawn location chosen directly. |
| TASK-F15 escort spawning by route threat | UNKNOWN | Whether the port spawns escorts from route-threat assessment is not covered by this spec's sources. |
| TASK-F16 guide stack / member reassignment | NOT PORTED | DCS AI tasking replaces guides entirely. |
| TASK-F17 Bresenham route difficulty | NOT PORTED | No difficulty scoring. |
| TASK-F18/F19 engage tasks & allocation | NOT PORTED | DCS native AI acquires/engages targets; EECH's one-member-per-target balancing and 16 km cap are lost (PROXY via DCS ROE at best). |
| TASK-F20/F21 biased route generation | NOT PORTED | Straight-line or hand-authored DCS waypoints; no valley-hugging/side-avoidance route search. |
| TASK-F22 waypoint type semantics | PROXY | DCS waypoint actions (orbit, land, attack group) stand in for EECH waypoint types; no CAP_START/CAP_LOOP loop mechanics, no ESCORT virtual waypoint. |
| TASK-F23 landing slots & locks | NOT PORTED | Explicitly out of scope in the port; DCS airbase parking is engine-managed, no reserve/free accounting. |
| TASK-F24 keysite scoring for task origin | UNKNOWN | Port spawn-origin selection logic not verified here. |
| TASK-F25 kill/loss per task | NOT PORTED | No per-task kill ledger. |
| TASK-F26 helicopter troops/fuel prep | NOT PORTED | DCS spawns with default fuel; no quarter-tank fuel planning. |

## 6. Open questions

1. **Lowest-positive-suitability wins** (assign.c:497-501): picking the *minimum* positive suitability is confirmed in code, but whether this was intended ("least over-qualified") or an inverted comparison bug is undocumented. A port should replicate the behavior, not the guess.
2. **Difficulty rating unused in total**: `assess_task_difficulty` loads db `difficulty_rating` into `task_level` but never adds it (task.c:756 vs :907); the 10-factor comment block (:711-725) is aspirational. Confirm nothing else reads `task_level`-style contributions.
3. **INT_TYPE_POINTS_VALUE source**: `award_points_for_task_completion` reads INT_TYPE_POINTS_VALUE (task.c:523) while the db has `task_completed_score`; the accessor mapping between the two was not traced in these files.
4. **task_user_data baselines**: which creator/assignment site writes FLOAT_TYPE_TASK_USER_DATA (member counts for BAI/CAS/SEAD/ESCORT, efficiency for strikes) was not located in the covered files — likely in order generation or objective messaging.
5. **wait_for_end_task / delay_task_assignment consumers**: db fields confirmed, but their runtime consumers (mission end gating, delayed assignment) live outside the covered files.
6. **Dead code**: `validate_task_generation` real body `#if 0` (taskgen.c:2377-2432); engage dead-target terminate path commented out after a crash (engage.c:953-963); `debug_engage_targets_in_area` engages regardless of side (debug tool, engage.c:397-509); LANDING_ROUTE_CHECK debug lock validation (landing.h:67).
7. **BARCAP vs CAP stop durations**: both take a caller-supplied `duration` (taskgen.c:603/:784); the standard values passed by order generation (other than the 15-min defensive CAP at keysite.c:915) belong to Spec 06.
8. **Takeoff queue ordering**: `takeoff_queue_root` (landing.h:89) manipulation was only found in debug/event code; the exact enqueue policy for AI members awaiting takeoff clearance was not fully traced.
9. **`waypoint_reached_return_value` / `check_waypoint_action` semantics** (wp_dbase.h:85-89): consumed by guide update code (`gd_updt.c`/`gd_nav.c`), not traced in detail here (low-level steering, out of scope).
