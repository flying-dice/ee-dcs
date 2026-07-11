# EECH Spec 04 — High-Level AI Task Generation

Sources:
- `aphavoc/source/ai/highlevl/highlevl.c` (scheduler + all `create_*_tasks` generators)
- `aphavoc/source/ai/highlevl/highlevl.h` (FOW constants)
- `aphavoc/source/ai/highlevl/order.c` (order-of-battle / division initialisation)
- `aphavoc/source/ai/highlevl/suitable.c` (group-to-task suitability matrix)
- `aphavoc/source/ai/taskgen/taskgen.c` (task creation plumbing, per-task expiry/waypoints)
- `aphavoc/source/entity/special/task/ts_dbase.h` / `ts_dbase.c` (task database: priorities, AI-stat requirements)
- Supporting citations: `aphavoc/source/entity/special/sector/sector.c`, `aphavoc/source/entity/special/session/ss_creat.c`, `aphavoc/source/entity/special/keysite/ks_dbase.h`, `aphavoc/source/entity/special/group/gp_dbase.c`, `aphavoc/source/entity/en_misc/en_misc.c`, `aphavoc/source/ai/taskgen/assign.c`, `aphavoc/source/entity/special/group/gp_msgs.c`, `modules/maths/constant.h`

All paths below are relative to `E:\eech_source_code\`. `ONE_MINUTE` = 60 s, `ONE_HOUR` = 3600 s (`eech modules/maths/constant.h:163,166`).

## 1. Overview

`start_high_level_ai` (`eech aphavoc/source/ai/highlevl/highlevl.c:181`) is the server-only brain of the dynamic campaign. On session start it initialises and normalises the four influence maps (importance, base-distance, air-defence, surface-defence; imaps are specced elsewhere), then registers a set of periodic update functions: **twelve task generators** plus imap re-normalisation, fog-of-war decay, sector side-count refresh, and campaign triggers. Two schedules exist — skirmish and campaign — selected by `get_game_type ()` (`highlevl.c:218`).

Every generator follows the same pattern:

1. For each force (side), scan a registry (enemy ground groups, enemy keysites, or own keysites) collecting up to `MAX_HIGHLEVEL_TARGET_CHECKS` (160) candidates with a scalar rating built from imap lookups, sector-side ratio, and entity state.
2. Sort candidates descending by rating (`quicksort_entity_list`, descending: partition uses `>` comparisons — `eech aphavoc/source/entity/en_misc/en_misc.c:79-118`; index 0 is the best candidate).
3. Take the top N (per-generator cap), and for each candidate whose rating is within `MIN_TASK_CREATION_RATIO` (0.75) of the best, apply duplicate-task guards, per-sector task caps, and fog-of-war (FOW) gates, then emit a task entity via the `taskgen.c` factories with
   `priority = (rating / max_rating) * task_database[TASK_TYPE].task_priority`.
4. Several generators fork on FOW: with insufficient FOW knowledge the strike is **downgraded to a RECON task** on the same objective (BAI, SEAD) or a recon is issued first with the strike created later by the reaction system (keysite strike, troop insertion). OCA strike/sweep simply skip the target when FOW is insufficient (no recon fallback).

Emitted tasks are entities parked on the start keysite's `LIST_TYPE_UNASSIGNED_TASK` list; the assignment engine (`assign.c`, out of this file's generator scope but summarised in §4) later picks an idle group at that keysite using the `suitable.c` group×task suitability matrix. `order.c`, despite its name, performs one-time **order-of-battle division initialisation**, not per-tick order dispatch.

## 2. Data model

| Item | Description | Source |
|---|---|---|
| `target_list[160]`, `target_rating[160]` | static scratch arrays for candidate scan; `MAX_HIGHLEVEL_TARGET_CHECKS` = 160 | `eech highlevl.c:84,108-112` |
| `importance_rating, air_defence_rating, surface_defence_rating, base_distance_rating` | static floats holding per-candidate imap lookups | `eech highlevl.c:123-127` |
| `MIN_TASK_CREATION_RATIO` = 0.75 | candidate must rate ≥ 0.75 × best candidate | `eech highlevl.c:86` |
| Per-generator caps | `CREATE_CAS_TASK_COUNT` 2, `MAX_SECTOR_CAS_TASK_COUNT` 1, `CREATE_BAI_TASK_COUNT` 2, `MAX_SECTOR_BAI_TASK_COUNT` 1, `CREATE_KEYSITE_STRIKE_TASK_COUNT` 3, `CREATE_OCA_STRIKE_TASK_COUNT` 1, `CREATE_OCA_SWEEP_TASK_COUNT` 2, `CREATE_TROOP_INSERTION_TASK_COUNT` 2, `CREATE_SEAD_TASK_COUNT` 2, `MAX_SECTOR_SEAD_TASK_COUNT` 1, `CREATE_TRANSFER_TASK_COUNT` 3 | `eech highlevl.c:88-102` |
| `FOG_OF_WAR_DECAY_RATE` = 30.0 s | FOW decay tick period and per-tick decrement | `eech highlevl.h:67`; decay applied per side in `sector.c:552-553` |
| `DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE` = 4 h | default `FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE`; session clamps it to [8×30 s, 8 h] | `eech highlevl.h:69`, `eech ss_creat.c:213` |
| `struct TASK_DATA` (`task_database[NUM_ENTITY_SUB_TYPE_TASKS]`) | per-task-type record: `task_priority` (float), `difficulty_rating`, target class/source/type, `minimum_member_count`, ROE, `engage_enemy`, `escort_required_threshold`, `primary_task`, `movement_type`, `landing_types` (bitmask), `ai_stats` {air attack, ground attack, movement speed, movement stealth, cargo space, troop space} | `eech aphavoc/source/entity/special/task/ts_dbase.h:67-137`; table at `ts_dbase.c:100` |
| `ESCORT_NEVER` = 15, `ESCORT_CRITICAL` = 6 | escort threshold sentinels | `eech ts_dbase.h:154-156` |
| Task entity attributes | created with sub-type, task id (wraps at `(1<<NUM_TASK_ID_BITS)-1`), `FLOAT_TYPE_EXPIRE_TIMER`, `FLOAT_TYPE_TASK_PRIORITY`, `INT_TYPE_CRITICAL_TASK`, movement type, route length, side; optional `FLOAT_TYPE_STOP_TIMER`; route node/waypoint-type/formation arrays; parented to start keysite `LIST_TYPE_UNASSIGNED_TASK` if `primary_task`; inserted into objective sector's `LIST_TYPE_SECTOR_TASK` | `eech aphavoc/source/ai/taskgen/taskgen.c:303-436` |
| `FLOAT_TYPE_TASK_USER_DATA` | per-task payload: target group member count (BAI `taskgen.c:589-593`, CAS `:972-976`, SEAD `:1624-1628`, escort `:1115-1119`), or target keysite efficiency (ground strike `:1292-1296`, anti-ship `:506-510`), or cargo sub-type (supply `:1715`) | `eech taskgen.c` (lines as listed) |
| `force_raw->task_generation[sub_type].created/completed/failed` | per-force per-task-type counters; `created` also supplies the task id | `eech taskgen.c:209,303` |
| `group_task_array[NUM_GROUPS][NUM_TASKS]` | precomputed float suitability matrix, built once at init | `eech aphavoc/source/ai/highlevl/suitable.c:81-241` |
| Keysite DB flags | `minimum_efficiency`, `oca_target`, `recon_target`, `ground_strike_target`, `ship_strike_target`, `troop_insertion_target` — per keysite type. DATA-DRIVEN (values per keysite sub-type in `ks_dbase.c`); reader: `keysite_database[type]` (`eech ks_dbase.h:78-104`) | `eech aphavoc/source/entity/special/keysite/ks_dbase.h:78-104` |
| Group DB fields used here | `frontline_flag`, `ai_stats` (incl. `air_attack_strength`), `default_landing_type`, `default_entity_type`, `default_engage_enemy`, `movement_type`, `minimum_idle_count`. DATA-DRIVEN (per group sub-type in `gp_dbase.c`); reader: `group_database[type]` | `eech aphavoc/source/entity/special/group/gp_dbase.c` (table), `gp_dbase.h` (struct) |
| `GROUP_FRONTLINE_FLAG_*` | `NONE / …​ / ARTILLERY` enum; `INT_TYPE_FRONTLINE` on groups | `eech aphavoc/source/entity/special/group/group.h:202` |
| Sector helpers | `get_local_sector_side_ratio (x,z,side)` (`sector.c:298`), `get_sector_fog_of_war_value (sector,side)` (`sector.c:510`), `get_sector_task_type_count (sector,type,side)` (`sector.c:639`) | `eech aphavoc/source/entity/special/sector/sector.c` |

### Task database rows relevant to generation (all `eech ts_dbase.c`, entry start line given)

| Task type | task_priority | engage_enemy | movement | landing_types | required ai_stats (air/gnd/speed/stealth/cargo/troop) | entry line |
|---|---|---|---|---|---|---|
| ADVANCE | 9 | F | GROUND | GROUND | 0/0/0/0/0/0 | 163 |
| ANTI_SHIP_STRIKE | 7 | T | AIR | FW+HC | 0/5/3/0/0/0 | 223 |
| BAI | 4 | T | AIR | FW+HC | 0/6/2/0/0/0 | 284 |
| BARCAP | 7 | T | AIR | FW+HC | 6/0/3/0/0/0 | 345 |
| BDA | 9 | F | AIR | HC | 0/0/3/5/0/0 | 406 |
| CLOSE_AIR_SUPPORT | 6 | T | AIR | FW+HC | 0/8/2/0/0/0 | 466 |
| COASTAL_PATROL | 1 | F | SEA | SEA | 0/0/0/0/0/0 | 527 |
| COMBAT_AIR_PATROL | 5 | T | AIR | FW+HC | 6/0/0/0/0/0 | 587 |
| ENGAGE | 10 | T | ALL | all | 0/0/0/0/0/0 | 648 |
| ESCORT | 7 | T | AIR | FW+HC | 4/2/0/0/0/0 | 713 |
| GROUND_STRIKE | 9 | T | AIR | FW+HC | 0/8/0/0/0/0 | 834 |
| OCA_STRIKE | 6 | T | AIR | FW only | 0/6/5/0/0/0 | 1025 |
| OCA_SWEEP | 7 | T | AIR | FW only | 5/0/5/0/0/0 | 1085 |
| RECON | 7 | F | AIR | HC | 0/0/3/5/0/0 | 1145 |
| REPAIR | 5 | F | AIR | HC | 0/0/0/0/6/0 | 1205 |
| RETREAT | 9 | F | GROUND | GROUND | 0/0/0/0/0/0 | 1265 |
| SEAD | 9 | T | AIR | FW+HC | 0/6/0/0/0/0 | 1325 |
| SUPPLY | 4 | F | AIR | FWT+HC | 0/0/0/0/5/0 | 1386 |
| TRANSFER_FIXED_WING | 5 | F | AIR | FW+FWT | 0/0/0/0/0/0 | 1577 |
| TRANSFER_HELICOPTER | 7 | F | AIR | HC | 0/0/0/0/0/0 | 1637 |
| TROOP_INSERTION | 10 | F | AIR | HC | 0/0/0/0/0/8 | 1696 |
| TROOP_MOVEMENT_INSERT_CAPTURE | 5 | T | GROUND | PEOPLE | 0/0/0/0/0/0 | 1755 |
| TROOP_MOVEMENT_INSERT_DEFEND | 5 | T | GROUND | PEOPLE | 0/0/0/0/0/0 | 1814 |
| TROOP_MOVEMENT_PATROL | 5 | T | GROUND | PEOPLE | 0/0/0/0/0/0 | 1873 |

(FW = LANDING_FIXED_WING, FWT = LANDING_FIXED_WING_TRANSPORT, HC = LANDING_HELICOPTER.)

## 3. Features

### TASKGEN-F1 — `start_high_level_ai` scheduler

Server-only (`get_comms_model () == COMMS_MODEL_SERVER`, `eech highlevl.c:187`). Initialises imaps + normalisations + sector side count (`highlevl.c:201-211`), then registers update functions. `add_high_level_ai_function (fn, frequency, start_time)` converts the desired wall-clock start into a phase offset: `offset = fmod (start_time − elapsed_time, frequency)`, wrapped positive; asserts `start_time ∈ [0, 24 h)`, `frequency ∈ (0, 24 h]` and that frequency divides 24 h exactly (`eech highlevl.c:346-369`).

**Generator schedule** (period s / offset s):

| Generator | Skirmish (`highlevl.c:220-242`) | Campaign (`highlevl.c:246-268`) |
|---|---|---|
| create_cas_tasks | 360 / 0 | 900 / 0 |
| create_sead_tasks | 600 / 2 | 720 / 180 |
| create_advance_and_retreat_tasks | 900 / 12 | 720 / 12 |
| create_artillery_strike_tasks | 720 / 8 | 900 / 45 |
| create_keysite_strike_tasks | 600 / 15 | 450 / 15 |
| create_troop_patrol_tasks | 600 / 5 | 300 / 5 |
| create_fixed_wing_transfer_tasks | 900 / 34 | 900 / 150 |
| create_troop_insertion_tasks | 120 / 60 | 120 / 60 |
| create_bai_tasks | 600 / 90 | 1200 / 300 |
| create_helicopter_transfer_tasks | 600 / 180 | 450 / 120 |
| create_oca_sweep_tasks | 1200 / 240 | 1800 / 90 |
| create_oca_strike_tasks | 1800 / 300 | 1800 / 390 |

**Shared functions** (both modes, `highlevl.c:272-285`): normalise importance / base-distance / air-defence / surface-defence imaps every 120 s at offsets 20/40/60/80; `update_client_server_sector_fog_of_war` every `FOG_OF_WAR_DECAY_RATE` = 30 s at offset 8; `update_client_server_sector_side_count` every 60 s at offset 15; `update_campaign_triggers` every 1 s at offset 0. `stop_high_level_ai` removes all of the above and deinitialises imaps (`highlevl.c:293-340`).

| Constant | Value | Source |
|---|---|---|
| FOW tick / decay | 30 s per tick, −30 s knowledge per tick per side | `eech highlevl.h:67`, `eech sector.c:552-553` |
| FOW maximum | default 4 h; clamped to [240 s, 8 h] at session create | `eech highlevl.h:69`, `eech ss_creat.c:213` |

### TASKGEN-F2 — `create_advance_and_retreat_tasks` (`eech highlevl.c:375-569`)

- **Cadence**: 900/12 skirmish, 720/12 campaign.
- **Scan**: own force's `LIST_TYPE_GROUND_REGISTRY` groups with `group_database[sub_type].frontline_flag`, alive, `GROUP_MODE != BUSY`, all members awake (`highlevl.c:433-437`).
- **Group rating** (own-group selection, not a target): `1.0 × (1 − imap BASE_DISTANCE[enemy_side])` + `1.0 × imap BASE_DISTANCE[own side]` at the group's sector — i.e. prefers groups far from the enemy base and deep in friendly territory (`highlevl.c:454-460`).
- **Move selection**: for the best-rated groups in order, examine all road-node links from the group's current `route_node`. A destination node qualifies if not occupied by an allied group (`road_nodes[to].side_occupying != side`), the road link is unbroken (`get_road_link_breaks == 0`), and inside the adjusted map area. Destination rating = `2.0 × imap BASE_DISTANCE[enemy_side]` at the node's sector; must exceed the group's own rating to be chosen (`highlevl.c:505-543`).
- **Emission**: sends `ENTITY_MESSAGE_GROUND_FORCE_ADVANCE` to the group with the best node (`highlevl.c:547`). The handler (`eech gp_msgs.c:536`, `:850`) creates `ENTITY_SUB_TYPE_TASK_ADVANCE` or `TASK_RETREAT` via `create_ground_force_task` — ground movement, waypoints CONVOY → SUB_ROUTE_NAVIGATION → REVERSE_CONVOY → DEFEND, expiry **12 h**, priority = DB priority 9 (`eech taskgen.c:1184-1215`, `ts_dbase.c:163,1265`).
- **Caps**: exactly **one group moved per force per tick** (`break` after first successful notify, `highlevl.c:561`). No FOW gate, no ratio gate (all candidates tried in rating order).

### TASKGEN-F3 — `create_bai_tasks` (`eech highlevl.c:575-809`)

- **Cadence**: 600/90 skirmish, 1200/300 campaign.
- **Scan**: every *other* force's ground registry; groups with `INT_TYPE_FRONTLINE > 1` (i.e. behind-the-line / second echelon), alive, and not keysite-attached (`GROUP_LIST_TYPE != LIST_TYPE_KEYSITE_GROUP`) (`highlevl.c:637-641`).
- **Rating** (max 7.0): `2.0 × (1 − imap AIR_DEFENCE[enemy])` + `3.0 × imap BASE_DISTANCE[own]` + `2.0 × sector_side_ratio[own]` (`highlevl.c:672-683`). Dead (commented-out) terms: importance and surface-defence contributions (`highlevl.c:669,675`). Candidates stored only if rating > 0.
- **Selection**: top `CREATE_BAI_TASK_COUNT` = 2; ratio gate ≥ 0.75; skip if group already object of a BAI task for this side; per-sector cap `MAX_SECTOR_BAI_TASK_COUNT` = 1 (`highlevl.c:733-754`).
- **FOW fork** (`highlevl.c:757-796`): if `sector FOW > 0.5 × FOW_max` → `create_bai_task` (critical = FALSE). Else → **downgrade to** `create_recon_task` (critical = TRUE). Both use `priority = (rating / 7.0) × task_priority[BAI] (= 4)`.
- **Emitted task**: BAI — air movement, single ATTACK waypoint at target group's position, expiry **20 min**, user-data = target member count (`eech taskgen.c:562-593`). Recon — HC-only, single RECON waypoint, expiry **10 min** (`taskgen.c:1477-1491`).

### TASKGEN-F4 — `create_cas_tasks` (`eech highlevl.c:815-1020`)

- **Cadence**: 360/0 skirmish, 900/0 campaign.
- **Scan**: enemy ground groups with `INT_TYPE_FRONTLINE == 1` (frontline proper), alive, not keysite-attached (`highlevl.c:877-881`).
- **Rating** (max 6.0): `1.0 × (1 − imap AIR_DEFENCE[enemy])` + `3.0 × imap BASE_DISTANCE[own]` + `2.0 × sector_side_ratio[own]` (`highlevl.c:912-923`). Dead terms: importance, surface-defence (`highlevl.c:909,915`).
- **Selection**: top `CREATE_CAS_TASK_COUNT` = 2; ratio ≥ 0.75; skip if already object of a CAS task; per-sector cap `MAX_SECTOR_CAS_TASK_COUNT` = 1 (`highlevl.c:973-993`).
- **No FOW gate** — CAS is created regardless of FOW (`highlevl.c:993-997`).
- **Emitted task**: `create_close_air_support_task` (critical = FALSE), priority = (rating/6.0) × 6; air movement, one ATTACK waypoint, expiry **20 min**, user-data = member count (`eech taskgen.c:945-976`).

### TASKGEN-F5 — `create_keysite_strike_tasks` (`eech highlevl.c:1026-1280`)

- **Cadence**: 600/15 skirmish, 450/15 campaign.
- **Scan**: enemy keysites (`LIST_TYPE_KEYSITE_FORCE`) in use and alive whose type has `ground_strike_target` or `ship_strike_target` (`highlevl.c:1089-1093`).
- **Rating** (max 9.0): `1.0 × (1 − imap AIR_DEFENCE[enemy])` + `4.0 × imap BASE_DISTANCE[own]` + `2.0 × (1 − keysite efficiency)` + `2.0 × sector_side_ratio[own]` (`highlevl.c:1110-1127`). Dead term: importance (`highlevl.c:1113`).
- **Selection**: top `CREATE_KEYSITE_STRIKE_TASK_COUNT` = 3; ratio ≥ 0.75. No per-sector task-count cap.
- **Recon-first fork** (`highlevl.c:1179`): if `keysite_database[type].recon_target` **or** `sector FOW < 0.25 × FOW_max` → create **RECON** (critical = FALSE) with the priority the strike *would* have had ((rating/9.0) × 9 for ground strike or × 7 for anti-ship), guarded against existing RECON/BDA/GROUND_STRIKE/ANTI_SHIP_STRIKE/TROOP_INSERTION/TM_INSERT_CAPTURE tasks on the keysite (`highlevl.c:1185-1205`). The actual strike is then created by the reaction system when the recon reports (see reaction spec).
- **Direct strike branch** (FOW sufficient and not a recon_target): requires keysite `efficiency ≥ keysite_database[type].minimum_efficiency` (below that it is not worth striking) and no existing GROUND_STRIKE/ANTI_SHIP_STRIKE/TROOP_INSERTION/TM_INSERT_CAPTURE task (`highlevl.c:1224-1231`). Emits `create_ground_strike_task` (priority = (rating/9.0) × 9, expiry **40 min**, user-data = keysite efficiency; `eech taskgen.c:1271-1296`) or, if `ship_strike_target`, `create_anti_ship_strike_task` (priority = (rating/9.0) × 7, expiry **30 min**; `taskgen.c:485-510`). Both critical = FALSE, single ATTACK waypoint.

### TASKGEN-F6 — `create_oca_strike_tasks` (`eech highlevl.c:1286-1467`)

- **Cadence**: 1800/300 skirmish, 1800/390 campaign.
- **Scan**: enemy keysites in use, alive, `keysite_database[type].oca_target` (`highlevl.c:1349-1353`).
- **Rating** (max 7.0): `1.0 × (1 − imap AIR_DEFENCE[enemy])` + `4.0 × imap BASE_DISTANCE[own]` + `2.0 × sector_side_ratio[own]` (`highlevl.c:1370-1381`).
- **Selection**: top `CREATE_OCA_STRIKE_TASK_COUNT` = 1; ratio ≥ 0.75.
- **FOW gate** (no recon fallback): requires `sector FOW ≥ 0.25 × FOW_max`, else nothing is created (`highlevl.c:1433`). Guards: no existing OCA_STRIKE/BDA/TROOP_INSERTION/TM_INSERT_CAPTURE on the keysite (`highlevl.c:1435-1440`).
- **Emitted task**: `create_oca_strike_task` (critical = **TRUE**), priority = (rating/7.0) × 6; FW-only landing type, one ATTACK waypoint, expiry **30 min** (`eech taskgen.c:1347-1361`).

### TASKGEN-F7 — `create_oca_sweep_tasks` (`eech highlevl.c:1473-1654`)

Identical structure to F6 with these differences:
- **Cadence**: 1200/240 skirmish, 1800/90 campaign.
- **Selection**: top `CREATE_OCA_SWEEP_TASK_COUNT` = 2 (`highlevl.c:1602`).
- Guards check OCA_SWEEP instead of OCA_STRIKE (`highlevl.c:1622-1626`); same FOW ≥ 0.25 × max gate (`highlevl.c:1620`), same rating formula/max 7.0 (`highlevl.c:1557-1568`).
- **Emitted task**: `create_oca_sweep_task` (critical = TRUE), priority = (rating/7.0) × 7; FW-only, ATTACK waypoint, expiry **30 min** (`eech taskgen.c:1411-1425`). Note: OCA sweep's DB ai_stats require air-attack 5 + speed 5, so it selects fighters, whereas OCA strike (ground 6 + speed 5) selects attack aircraft.

### TASKGEN-F8 — `create_troop_insertion_tasks` (`eech highlevl.c:1660-1912`)

- **Cadence**: 120/60 both modes.
- **Scan**: enemy keysites in use, alive, `troop_insertion_target`, **and** `efficiency < keysite_database[type].minimum_efficiency` (i.e. suppressed enough to capture) (`highlevl.c:1728-1732`).
- **Rating** (max 9.0): `1.0 × (1 − imap AIR_DEFENCE[enemy])` + `3.0 × imap BASE_DISTANCE[own]` + `3.0 × (1 − efficiency)` + `2.0 × sector_side_ratio[own]` (`highlevl.c:1749-1766`). Dead term: importance (`highlevl.c:1752`).
- **Selection**: top `CREATE_TROOP_INSERTION_TASK_COUNT` = 2; ratio ≥ 0.75.
- **Recon-first fork** (`highlevl.c:1819`): if `recon_target` or `sector FOW < 0.2 × FOW_max` → RECON (critical = FALSE, priority = (rating/9.0) × 10) guarded against existing RECON/BDA/TROOP_INSERTION/TM_INSERT_CAPTURE (`highlevl.c:1825-1834`). Note the **0.2** threshold here (vs 0.25 elsewhere).
- **Direct branch**: requires `INT_TYPE_KEYSITE_USABLE_STATE != KEYSITE_STATE_USABLE` (only capture non-operational keysites) and no existing TROOP_INSERTION/TM_INSERT_CAPTURE (`highlevl.c:1853-1858`). Emits `create_troop_insertion_task` (critical = TRUE, priority = (rating/9.0) × 10).
- **Backup insertion** (`highlevl.c:1876-1897`): after a successful insertion task, if the keysite's owning side differs and has no TROOP_INSERTION / TM_INSERT_CAPTURE / TM_INSERT_DEFEND task and `< 2` TM_PATROL tasks on it, a **defensive** troop insertion is also created *for the keysite's own side* at the same priority.
- **Task shape** (`eech taskgen.c:1838-1903`): drop-off point pulled back from the destination toward the start keysite by 1500 m (airbase) or 750 m (other), halved again for same-side (defend) insertions; waypoints NAVIGATION (+50 m alt) → PREPARE_FOR_INSERTION (+5 m) → TROOP_INSERT → WAIT → NAVIGATION; expiry **45 min**; HC-only.

### TASKGEN-F9 — `create_sead_tasks` (`eech highlevl.c:1918-2126`)

- **Cadence**: 600/2 skirmish, 720/180 campaign.
- **Scan**: enemy ground registry; groups alive, **not** frontline (`!frontline_flag`) and with `group_database[type].ai_stats.air_attack_strength == 10` (`highlevl.c:1977-1981`). In the ground registry this selects dedicated AA/SAM groups (group DB types with air = 10: ANTI_AIRCRAFT; also ASSAULT_SHIP / fighters carry air = 10 but live in sea/air registries — `eech gp_dbase.c`, DATA-DRIVEN).
- **Rating** (max 7.0): `4.0 × imap BASE_DISTANCE[own]` + `3.0 × sector_side_ratio[own]` (`highlevl.c:1998-2013`). Dead terms: importance, air-defence, and an alternative `max_rating = 10.0` (`highlevl.c:2001,2004,2012`).
- **Selection**: top `CREATE_SEAD_TASK_COUNT` = 2; ratio ≥ 0.75; skip if group is already object of a RECON **or** SEAD task; per-sector cap `MAX_SECTOR_SEAD_TASK_COUNT` = 1 (`highlevl.c:2047-2070`).
- **FOW fork** (`highlevl.c:2072-2113`): `FOW ≥ 0.25 × max` → `create_sead_task` (critical = FALSE); else → `create_recon_task` (critical = TRUE). Priority in both cases = (rating/7.0) × 9.
- **Emitted task**: SEAD — air, one ATTACK waypoint at the AA group, expiry **30 min**, user-data = member count (`eech taskgen.c:1597-1628`).

### TASKGEN-F10 — `create_fixed_wing_transfer_tasks` (`eech highlevl.c:2132-2346`)

- **Cadence**: 900/34 skirmish, 900/150 campaign.
- **Scan**: **own** keysites in use, `KEYSITE_STATE_USABLE`, with a fixed-wing landing entity (`highlevl.c:2194-2198`). For each, counts idle groups whose `default_landing_type == LANDING_FIXED_WING` (`highlevl.c:2206-2223`).
- **Rating** (max 8.0): `4.0 × imap BASE_DISTANCE[enemy]` (close to the enemy = needy) + `4.0 × (1 − min(idle_count, 4)/4)` (`highlevl.c:2258-2265`). Dead terms: importance / air-defence / surface-defence (`highlevl.c:2249-2255`).
- **Pairing**: sort descending; `keysite_count = min (count/2, CREATE_TRANSFER_TASK_COUNT = 3)`. Destination = i-th best keysite, donor = keysite from the bottom of the list (`loop2 = count−1`, decremented per created transfer). Requires destination not already object of a TRANSFER_FIXED_WING task and to have free landing sites (`get_keysite_landing_sites_available`) (`highlevl.c:2290-2334`). A rating-threshold check (`> max×0.5` / `< max×0.5`) and a `free_landing_sites >= 4` check exist but are commented out (dead; `highlevl.c:2300,2316`).
- **Priority**: `((rating_dest − rating_donor) / 8.0) × task_priority[TRANSFER_FIXED_WING] (= 5)` (`highlevl.c:2321`).
- **Emitted task**: `create_transfer_task (side, TRANSFER_FIXED_WING, priority, donor, dest, FALSE)` — critical = TRUE, one NAVIGATION waypoint at the destination keysite, expiry **10 min**; aborts if start == destination unless emergency (`eech taskgen.c:1770-1790`). The moved group re-homes to the destination keysite on assignment via the task's return keysite (`eech assign.c:570-579`).

### TASKGEN-F11 — `create_helicopter_transfer_tasks` (`eech highlevl.c:2352-2566`)

Identical to F10 with landing type `ENTITY_SUB_TYPE_LANDING_HELICOPTER` throughout (`highlevl.c:2418-2537`), task type `TRANSFER_HELICOPTER` (DB priority 7, `ts_dbase.c:1637`).
- **Cadence**: 600/180 skirmish, 450/120 campaign.
- Same rating formula (max 8.0), same pairing, same commented-out threshold checks (`highlevl.c:2520,2536`), same priority formula with task_priority = 7 (`highlevl.c:2541`).

### TASKGEN-F12 — `create_sead_tasks_around_keysite` (reaction helper, `eech highlevl.c:2576-2687`)

Not scheduled; called by the reaction system (reaction.c — specced elsewhere) when a strike task needs its target area cleaned of SAMs.
- Scans the *keysite-owning* side's enemy... precisely: `enemy_side = keysite's side`, iterates that force's `LIST_TYPE_INDEPENDENT_GROUP` for groups with `default_entity_type == ENTITY_TYPE_ANTI_AIRCRAFT`, alive, not already object of a SEAD or RECON task for `this_side` (`highlevl.c:2616-2635`).
- Range gate: within `MAX_KEYSITE_SEAD_RANGE` = 4 km of the keysite (squared-range compare) (`highlevl.c:2572,2643`).
- FOW gate: group's sector FOW > 0.25 × max (`highlevl.c:2653`).
- Emits up to `MAX_KEYSITE_SEAD_COUNT` = 3 SEAD tasks (critical = TRUE), priority inherited from the originating task's `FLOAT_TYPE_TASK_PRIORITY` (`highlevl.c:2574,2610,2659`). Returns count.

### TASKGEN-F13 — `create_troop_patrol_tasks` + `create_patrol_task` (`eech highlevl.c:2693-2830`)

- **Cadence**: 600/5 skirmish, 300/5 campaign.
- **Scan**: ALL forces' own keysites of type FARP, MILITARY_BASE, or AIRBASE (`highlevl.c:2759-2761`).
- For each such keysite, iterates keysite groups of type `GROUP_INFANTRY_PATROL` (plain INFANTRY commented out): counts them; any that are alive, idle, and awake get a patrol task (`highlevl.c:2773-2786`).
- **Auto-spawn**: if the keysite has fewer than `groups_limit = 1` infantry-patrol groups, one is **created** via `create_faction_members (keysite, GROUP_INFANTRY_PATROL, FORMATION_COMPONENT_INFANTRY, 4 members, side, pos, TRUE, FALSE)` at a point 300–350 m from the keysite at a deterministic angle (`(keysite index mod 6) × 60°`), added to a division, then tasked (`highlevl.c:2792-2819`). This generator is the one place high-level AI spawns units.
- **Task** (`create_patrol_task`, `highlevl.c:2693-2733`): requires group idle + alive; `create_troop_movement_patrol_task (side, keysite_pos, radius = 300 + sfrand1()×100 m, keysite)` and **direct assignment** via `assign_task_to_group (…, TASK_ASSIGN_ALL_MEMBERS)` (bypasses the unassigned-task pool); task destroyed on assignment failure.
- **Route** (`eech taskgen.c:2089-2206`): if the keysite 3D model has a `PATROL_ROUTE` sub-object, waypoints follow it (±5 m jitter, TAXI waypoints); otherwise 6 auto waypoints on a circle of radius `(0.8 + 0.2×frand1()) × radius` starting at angle `(keysite index mod 6) × 60°`; last waypoint becomes TROOP_DEFEND; remaining slots (to 16) duplicate the last. Ground movement, **no expiry** (expire_timer = 0), priority = DB priority 5, critical = FALSE.

### TASKGEN-F14 — `create_artillery_strike_tasks` (`eech highlevl.c:2838-3119`)

Unlike the others this generator does not create task entities via the unassigned pool — it directly commands artillery groups to engage.
- **Cadence**: 720/8 skirmish, 900/45 campaign.
- **Shooters**: own ground groups with `INT_TYPE_FRONTLINE == GROUP_FRONTLINE_FLAG_ARTILLERY` (`highlevl.c:2898`).
- **Targets**: (a) enemy ground groups with `INT_TYPE_FRONTLINE != GROUP_FRONTLINE_FLAG_NONE`; (b) enemy keysites that are `ground_strike_target`, in use, alive, with `efficiency ≥ FLOAT_TYPE_MINIMUM_EFFICIENCY`, and not already object of GROUND_STRIKE / TROOP_INSERTION / TM_INSERT_CAPTURE for this side (`highlevl.c:2937-3024`).
- **Assignment loop** (`highlevl.c:3036-3105`): for each artillery group with `get_local_group_max_weapon_range > 0`, find the first listed target within (squared) weapon range whose sector FOW > 0.25 × max. Groups fire via `engage_targets_in_group (group, target, TRUE)` for group targets or `engage_targets_in_area (group, target_pos, 1 km radius, TASK_TARGET_TYPE_BUILDING, TRUE)` for keysites (engage.c plumbing). On success the target is removed from the list and `create_reaction_to_artillery_fire (group, target)` is invoked (reaction.c — counter-battery, specced elsewhere).
- **Cap**: stops after `MAX_ARTILLERY_STRIKE_COUNT` = 5 assignments per force per tick, or when targets are exhausted (`highlevl.c:2836,3101`).
- No rating/sort, no priority computation, no ratio gate.

### TASKGEN-F15 — `create_task` plumbing (`eech taskgen.c:114-439`) and per-factory parameters

`create_task (sub_type, side, movement_type, start_keysite, end_keysite, originator, critical, expire_timer, stop_timer, objective, priority, …varargs route)`:
- Varargs are (position, dependent entity, waypoint type, formation) quadruples terminated by `terminator_point = (−1,−1,−1)` (`taskgen.c:97-98,217-271`); positions are `ceil`ed to integers.
- `validate_task_generation` always returns TRUE — the per-force valid-task check and `TASK_SAFE_LIMIT` cap are `#if 0` dead code (`taskgen.c:2373-2433`, `TASK_SAFE_LIMIT` = 0 at `:89`).
- Task id = per-force per-type created counter, wrapped to `(1<<NUM_TASK_ID_BITS)−1` (`taskgen.c:303-310`).
- If `task_database[sub_type].primary_task`, the task is parented to the start keysite's `LIST_TYPE_UNASSIGNED_TASK` (asserts a start keysite exists) (`taskgen.c:376-381`). `get_task_start_keysite` resolves a NULL start keysite via `find_most_suitable_keysite_for_task` (landing-capability aware) and fails task creation if none found (`taskgen.c:2583-2618`).
- Task difficulty assessed at creation (`assess_task_difficulty`, `taskgen.c:383`); enemy force notified via `ENTITY_MESSAGE_TASK_CREATED` if the objective belongs to them (`taskgen.c:391-408`); task inserted into the objective's sector task list (used by the per-sector caps) (`taskgen.c:416-436`).
- `get_estimated_task_duration` = summed 2D waypoint range / 60 kts (`taskgen.c:2439-2537`).

**Expiry times by factory** (all `eech taskgen.c`): anti-ship 30 min (:485), BAI 20 min (:562), BARCAP 10 min (:690), BDA 30 min (:761), CAP 10 min (:877), CAS 20 min (:945), coastal patrol 30 min (:1014), escort 15 min (:1065), ground force (advance/retreat) 12 h (:1184), ground strike 40 min (:1271), OCA strike 30 min (:1347), OCA sweep 30 min (:1411), recon 10 min (:1477), repair 30 min (:1530), SEAD 30 min (:1597), supply 20 min (:1696), transfer 10 min (:1776), troop insertion 45 min (:1885), troop movement patrol none (:2184). CAP/BARCAP place 4 waypoints on an 8 km square around the centre at a random rotation (`taskgen.c:640-666,819-853`).

### TASKGEN-F16 — Group-to-task suitability (`eech suitable.c`)

`initialise_group_task_array` precomputes `suitability[group_type][task_type]` for every pair at campaign start (`suitable.c:223-241`); `get_group_to_task_suitability` is a pure table lookup (`suitable.c:212-217`).

`calculate_group_to_task_suitability` (`suitable.c:88-206`) — **critical gates** (any failure → 0.0, group can never do the task):
1. Movement type: task's `movement_type` must be `MOVEMENT_TYPE_ALL` or equal the group's (`suitable.c:115`).
2. Landing type: group's `default_landing_type` bit must be set in the task's `landing_types` mask (`suitable.c:120-124`).
3. `task.movement_speed ≤ group.movement_speed` (`suitable.c:129`).
4. `task.movement_stealth ≤ group.movement_stealth` (`suitable.c:136`).
5. `task.cargo_space ≤ group.cargo_space` (`suitable.c:143`).
6. `task.troop_space ≤ group.troop_space` (`suitable.c:150`).
7. `task.ground_attack_strength ≤ group.ground_attack_strength` (`suitable.c:157`).
8. `task.air_attack_strength ≤ group.air_attack_strength` (`suitable.c:164`).
9. If `task.engage_enemy`, group must have `default_engage_enemy` (`suitable.c:171-177`).

**Non-critical score** (`suitable.c:183-201`): start at 1.0; for each of air and ground attack strength where the task requires > 0, multiply by `min (group_stat / task_stat, 1.0)`. Given gates 7–8 the ratio is ≥ 1, so in practice the score is 1.0 for any group passing the gates; result ∈ [0,1] asserted. The effective suitability table is therefore the task ai_stats requirements in §2 crossed with the group database stats (DATA-DRIVEN, `gp_dbase.c`) — e.g. RECON/BDA demand stealth 5 + speed 3 (scout helicopters), CAS demands ground 8, OCA tasks demand speed 5 + FW landing (jets only), TROOP_INSERTION demands troop space 8 (transport helicopters).

**Consumption** (`eech assign.c:401-518`, `get_suitable_registered_group`): for a task parked at a keysite, iterate that keysite's groups; group must be un-piloted (no player lock), not an assault ship, `GROUP_MODE_IDLE`, awake (`sleep == 0`), same side, idle-count above `group_database[type].minimum_idle_count`, member count ≥ task's `minimum_member_count`, suitability > 0, pass task-specific checks and a locality/cruise-speed feasibility check. NOTE: the comparison keeps the group with the **lowest** positive suitability (`result < best_result` with `best_result` initialised to FLT_MAX, `assign.c:497`) — with the current data (score is effectively 1.0 or 0.0) this is a first-match tie-break, but the direction is inverted relative to the apparent intent (see §6).

### TASKGEN-F17 — Order of battle initialisation (`eech order.c`)

`initialise_order_of_battle` runs once per force at campaign creation (`order.c:690-721`). It builds the division tree used for group bookkeeping (division names, HQ keysites); it is **not** a runtime order-dispatch loop.
- **Armoured divisions** (`order.c:91-470`): counts PRIMARY_FRONTLINE + SECONDARY_FRONTLINE groups and SELF_PROPELLED_ARTILLERY groups; `division_count = max (ceil (frontline/12), ceil (artillery/2))` (`order.c:166-170`). Groups are dealt to divisions with fractional-remainder carry (`order.c:257-261`); within a division, groups are sorted by 2D distance from the division's seed group (first unassigned) and split into ARMOURED_COMPANYs of 3 frontline groups (`company_count = ceil (f_count/3)`, `order.c:353-383`) and ARTILLERY_COMPANYs of 1 artillery group each (`order.c:431-446`). Division HQ = closest friendly AIRBASE to the seed group (`order.c:307`).
- **Airborne divisions** (`order.c:476-530`): creates one HC, one FW and one transport division per force; per AIRBASE adds HC_ATTACK, HC_TRANSPORT, FW_ATTACK, FW_FIGHTER, FW_TRANSPORT companies; per ANCHORAGE (carrier) adds HC_ATTACK + HC_TRANSPORT companies.
- **Infantry divisions** (`order.c:536-568`): one INFANTRY_DIVISION per force; one INFANTRY_COMPANY per FARP / MILITARY_BASE / AIRBASE.
- **Carrier divisions** (`order.c:574-624`): one CARRIER_DIVISION per force; one CARRIER_COMPANY per ANCHORAGE with all sea-movement groups at that keysite attached.
- **Sweep-up** (`order.c:630-684`): any air/ground/sea registry group without a division gets `add_group_to_division (group, NULL)`.

## 4. Interactions

- **Consumes**: imap values via `get_imap_value` (imaps.c — Spec: influence maps); sector FOW / side ratio / task counts (`sector.c:298,510,639`); keysite DB flags and efficiencies (ks_dbase, DATA-DRIVEN); group DB frontline flags and ai_stats (gp_dbase, DATA-DRIVEN); road-node graph for advance/retreat.
- **Drives**: task entities into keysite `LIST_TYPE_UNASSIGNED_TASK` pools → assignment engine (`assign.c`) picks groups via TASKGEN-F16 and re-homes groups on transfer; escort assessment on assignment uses `escort_required_threshold` (`assign.c:598`). `ENTITY_MESSAGE_TASK_CREATED` to the enemy force feeds the reaction system (reaction.c) — which in turn calls back into TASKGEN-F12 (`create_sead_tasks_around_keysite`) and creates the deferred strikes behind the recon-first forks of F5/F8. Artillery engagement (F14) calls `engage_targets_in_group` / `engage_targets_in_area` (engage.c) and `create_reaction_to_artillery_fire` (reaction.c). Troop-insertion completion spawns TM_INSERT_CAPTURE / TM_INSERT_DEFEND ground tasks (`taskgen.c:1916-2087`).
- **Per-sector caps** rely on tasks registering into `LIST_TYPE_SECTOR_TASK` at creation (`taskgen.c:436`); duplicate-task guards rely on `entity_is_object_of_task`.
- `update_campaign_triggers` (1 s cadence) is registered here but belongs to the campaign-trigger spec.

## 5. Port mapping

Port context (given): the DCS port implements attack_waves (keysite strike 450 s/15 s, OCA strike 1800 s/390 s), cas_bai_sead (CAS 900 s no FOW gate; BAI 1200 s FOW>0.5; SEAD 720 s ≥0.25; OCA sweep 1800 s ≥0.25; artillery 900 s; post-sort strike-vs-recon fork, ratio ≥ 0.75, per-sector caps), a recon module, heli_war (anti-armour 480 s / hunter-killer 600 s / escort — a port-added composite with **no EECH generator counterpart**), troop (insertion 120 s, patrol 300 s), transfer (FW 900 s / HC 450 s economy-neutral proxy), ground_forces (advance/retreat 720 s). The port spawns fresh groups per task instead of assigning existing groups: no task engine/assignment, no suitable.c equivalent, no order dispatch. Port periods match EECH **campaign-mode** values throughout; the skirmish schedule is not represented.

| Feature | Status | Note |
|---|---|---|
| TASKGEN-F1 scheduler | PARTIAL | Campaign-mode periods/offsets reproduced per module (450/15, 1800/390 etc.); skirmish schedule and the fmod phase-offset mechanism vs elapsed time UNKNOWN. |
| TASKGEN-F2 advance/retreat | PARTIAL | ground_forces at 720 s matches campaign cadence; EECH moves one existing frontline group per force along road nodes via imap-rated links — port spawns fresh groups, road-node/one-group-per-tick semantics UNKNOWN. |
| TASKGEN-F3 BAI | PORTED (cas_bai_sead) | 1200 s, FOW>0.5 gate, strike-vs-recon fork, ratio ≥ 0.75, per-sector caps all match; targets are spawned rather than existing echelon-2 groups. |
| TASKGEN-F4 CAS | PORTED (cas_bai_sead) | 900 s, no FOW gate — matches EECH exactly. |
| TASKGEN-F5 keysite strike | PARTIAL (attack_waves) | 450 s/15 s matches; EECH recon-first fork (recon_target OR FOW<0.25) with reaction-created strike, efficiency ≥ minimum_efficiency gate, and anti-ship variant — coverage UNKNOWN. |
| TASKGEN-F6 OCA strike | PORTED (attack_waves) | 1800 s/390 s matches; EECH FOW ≥ 0.25 gate (no recon fallback) and cap of 1/tick — port gate handling UNKNOWN. |
| TASKGEN-F7 OCA sweep | PORTED (cas_bai_sead) | 1800 s, FOW ≥ 0.25 matches. |
| TASKGEN-F8 troop insertion | PARTIAL (troop) | 120 s matches; EECH gates (efficiency < minimum, keysite not USABLE, FOW < 0.2 recon fork) and the defender-side backup insertion — UNKNOWN. |
| TASKGEN-F9 SEAD | PORTED (cas_bai_sead) | 720 s, FOW ≥ 0.25, recon downgrade matches; EECH targets non-frontline AA groups with air_attack == 10. |
| TASKGEN-F10 FW transfer | PROXY (transfer) | 900 s matches; port is economy-neutral — EECH's donor(worst)→destination(best) pairing, idle-group-count rating and group re-homing NOT PORTED. |
| TASKGEN-F11 HC transfer | PROXY (transfer) | 450 s matches; same caveats as F10. |
| TASKGEN-F12 SEAD around keysite | NOT PORTED | Reaction-driven helper (4 km, 3 tasks, FOW>0.25); port has no reaction-dispatch counterpart per summary. |
| TASKGEN-F13 troop patrol | PORTED (troop) | 300 s matches; EECH auto-spawns 1 four-man infantry-patrol group per FARP/base/airbase and uses model-embedded or 6-point circular routes (300–350 m / 240–400 m radius). |
| TASKGEN-F14 artillery strike | PORTED (cas_bai_sead) | 900 s matches; EECH is direct engagement (range + FOW>0.25 gated, cap 5/force/tick) with counter-battery reaction — reaction side UNKNOWN. |
| TASKGEN-F15 create_task engine | NOT PORTED | Port spawns fresh groups per task; no task entities, ids, expiry timers, unassigned pools, or sector task lists (per-sector caps must be tracked differently). |
| TASKGEN-F16 suitable.c | NOT PORTED | No group-suitability matrix; spawn templates substitute for group selection. |
| TASKGEN-F17 order.c OOB | NOT PORTED | No division/company tree or HQ keysites in the port. |
| (port-only) heli_war | — | Anti-armour 480 s / hunter-killer 600 s / escort composite has no single EECH generator counterpart (EECH gets helicopter tasking implicitly via suitability on BAI/CAS/SEAD/recon/escort). |

## 6. Open questions

1. **assign.c suitability inversion**: `get_suitable_registered_group` keeps the group with the *lowest* positive suitability (`result < best_result`, `best_result = FLT_MAX`; `eech assign.c:435,497`). With current data all positive suitabilities are 1.0, so it acts as first-match, but the comparison direction contradicts "best group" intent. Faithful port target unclear.
2. **SEAD scan breadth**: the `air_attack_strength == 10` filter (`highlevl.c:1981`) is an exact-equality magic number tied to group DB data; if warzone data added an AA group with air = 9 it would be invisible to SEAD. Intended semantics ("dedicated SAM groups") inferred, not documented.
3. **Advance vs retreat**: `create_advance_and_retreat_tasks` only ever issues `ENTITY_MESSAGE_GROUND_FORCE_ADVANCE`; RETREAT tasks are created from a different message path (`gp_msgs.c:850`, reaction-side). Whether the generator name's "retreat" half was ever driven from highlevl.c is unclear (no retreat call in the file).
4. **Transfer donor sanity**: the donor is taken from the bottom of the *rated* list without checking it is not also a destination, that it differs from the destination, or that it actually has idle groups (checks at `highlevl.c:2300,2520` are commented out). Port fidelity question: reproduce the dead checks or the live behaviour?
5. **Keysite/group DB values**: all `keysite_database` flags/minimum efficiencies and `group_database` ai_stats are DATA-DRIVEN compiled tables (`ks_dbase.c`, `gp_dbase.c`); this spec cites the readers only. A companion data extraction would be needed to fix exact per-type values for the port.
6. **`create_troop_patrol_tasks` sides**: it iterates all forces including both sides symmetrically but has no FOW, imap, or priority logic at all — confirmation that the port's troop-patrol module likewise skips scoring.
7. **Dead code inventory** (documented, not to be ported as live): commented rating terms in BAI/CAS/keysite/TI/SEAD/transfer generators; `validate_task_generation` body (`taskgen.c:2377-2432`); `TASK_SAFE_LIMIT` (`taskgen.c:89`); transfer rating-threshold and free-landing-sites ≥ 4 checks (`highlevl.c:2300,2316,2520,2536`); `max_rating = 10.0` alternative in SEAD (`highlevl.c:2012`).
8. **`ai_log`**: DEBUG-build only (writes `AI.LOG` with day/HH:MM:SS timestamps, `highlevl.c:3127-3181`); release builds have no task-generation logging.
