# EECH Spec 02 — Forces, Reserves & Campaign Win Criteria

Sources:
- `aphavoc/source/entity/special/force/force.h`, `force.c`, `fc_creat.c`, `fc_updt.c`, `fc_int.c`, `fc_float.c`, `fc_msgs.c`, `fc_pack.c`
- `aphavoc/source/entity/system/en_types/en_force.h`, `en_force.c`, `en_side.h`, `en_side.c`
- `aphavoc/source/ai/parser/parsgen.c` (LIVE warzone parser), `aphavoc/source/ai/faction/parser.c` (LEGACY, not compiled)
- `aphavoc/source/ai/highlevl/setup.c`, `highlevl.c`; `aphavoc/source/ui_menu/ingame/campaign/campaign.c`, `campaign.h`, `ca_stat.c`
- `aphavoc/source/entity/special/sector/sector.c`; `aphavoc/source/entity/special/regen/rg_updt.c` (reserve consumer)
- `aphavoc/source/entity/special/keysite/keysite.c`, `ks_dstry.c`, `ks_int.c`, `ks_dbase.h`; `aphavoc/source/entity/mobile/aircraft/helicop/hc_dstry.c`
- Category assignment: `aphavoc/source/entity/mobile/aircraft/ac_dbase.c`, `ac_int.c`; `aphavoc/source/entity/mobile/vehicle/vh_dbase.c`, `vh_int.c`

## 1. Overview

EECH maintains one FORCE entity per combatant side (BLUE / RED). The force entity is the side-level ledger of the campaign: a live hardware census by category (`force_info_current_hardware`), a finite off-map reserve pool by category (`force_info_reserve_hardware`), kill/loss/group statistics, a sector-ownership count, task-generation statistics, and — in the original Razorworks design — a linked list of `campaign_criteria` that a 5-second server-side evaluator in `fc_updt.c` checked to decide campaign win/lose.

**CRITICAL DEAD-CODE FINDING for this whole spec:** in the community source (1.16.x), the *entire* campaign-criteria system is dead code:

1. The body of the force update function in `fc_updt.c` is wrapped in a single `/* ... */` block (eech `aphavoc/source/entity/special/force/fc_updt.c:86-495`). The registered server update function is an empty no-op.
2. The criteria parser lives in `aphavoc/source/ai/faction/parser.c`, which is **not compiled at all**: `ai/faction/Makefile.am` lists only `briefing.c faction.c popread.c routegen.c`, and the MSVC project uses `aphavoc/source/ai/parser/parsgen.c` as the warzone parser instead (`EECH-MSVC.vcproj:524`). Inside parser.c the `FILE_TAG_CAMPAIGN_CRITERIA` case is additionally commented out (eech `aphavoc/source/ai/faction/parser.c:916-1215`).
3. The `CAMPAIGN_CRITERIA_*` enum constants and `campaign_criteria_names[]` are referenced *only* from commented code and are **not defined anywhere in the tree** — the enum itself was deleted.
4. `add_force_campaign_critiera` / `get_force_campaign_criteria` in `force.c` are commented out (eech `aphavoc/source/entity/special/force/force.c:123-168, 173-205`), and the FORCE struct field `campaign_criteria` is never populated.

What actually ends the campaign in the shipped community build is an **event-driven keysite/gunship exhaustion check** in `fc_msgs.c` (`response_to_check_campaign_objectives`, eech `aphavoc/source/entity/special/force/fc_msgs.c:144-311`), triggered on keysite capture, keysite destruction, and helicopter kill. Both systems are specified below: the criteria system because it is the design-intent ground truth the port's `win_condition` is modelled on, and the live system because it is what EECH actually does.

Reserves, by contrast, are fully live: seeded from the warzone file, decremented on every runtime spawn, and gating the regeneration system (`rg_updt.c`).

## 2. Data model

### 2.1 FORCE entity struct — eech `aphavoc/source/entity/special/force/force.h:67-112`

| Field | Type | Purpose | Line |
|---|---|---|---|
| `force_name` | char[] | side short name ("BLUE"/"RED", copied at create) | force.h:69-70, fc_creat.c:167 |
| `keysite_force_root` | list_root | all keysites owned by this side | force.h:73 |
| `independent_group_root` | list_root | independent groups | force.h:74 |
| `pilot_root` | list_root | pilots on this side | force.h:75 |
| `division_root` | list_root | divisions | force.h:76 |
| `campaign_objective_root` | list_root | the side's campaign-objective keysites (LIST_TYPE_CAMPAIGN_OBJECTIVE) | force.h:77 |
| `air_registry_root` / `ground_registry_root` / `sea_registry_root` | list_root | group registries by domain | force.h:79-81 |
| `force_link`, `update_link` | list_link | child of SESSION (LIST_TYPE_FORCE) and of the update entity (LIST_TYPE_UPDATE) | force.h:83-85, fc_creat.c:183-185 |
| `task_generation[NUM_ENTITY_SUB_TYPE_TASKS]` | task_generation_type | per-task-type valid flag + created/completed/failed counters | force.h:87-88 |
| `campaign_criteria` | campaign_criteria_type* | linked list of win/lose criteria — **never populated (dead)** | force.h:90-91 |
| `force_info_current_hardware[NUM_FORCE_INFO_CATAGORIES]` | int | live census per hardware category | force.h:94 |
| `force_info_reserve_hardware[NUM_FORCE_INFO_CATAGORIES]` | int | finite off-map reserve pool per category | force.h:95 |
| `kills[NUM_ENTITY_SUB_TYPE_GROUPS]` / `losses[...]` / `group_count[...]` | int | per-group-type statistics | force.h:97-100 |
| `sector_count` | int | number of map sectors owned by this side | force.h:102-103 |
| `sleep` | float | update timer (FLOAT_TYPE_SLEEP) | force.h:105-106 |
| `force_attitude` / `colour` / `side` | bitfields | attitude, map colour, entity side | force.h:108-111 |

Note the struct has **no** `force_percentage`, `objective_sectors_percentage`, or `time_percentage` fields — the commented `fc_updt.c` code references them (`raw->force_percentage` etc.), proving the struct was cut down after the criteria system was removed. `fc_float.c` only implements `FLOAT_TYPE_SLEEP` (eech `aphavoc/source/entity/special/force/fc_float.c:95,180,206-210`); there is no surviving `FLOAT_TYPE_FORCE_PERCENTAGE` accessor for the force entity.

### 2.2 Hardware categories — eech `aphavoc/source/entity/system/en_types/en_force.h:258-270`

```
FORCE_INFO_CATAGORY_ARMED_FIXED_WING      = 0
FORCE_INFO_CATAGORY_UNARMED_FIXED_WING    = 1
FORCE_INFO_CATAGORY_ARMED_HELICOPTER      = 2
FORCE_INFO_CATAGORY_UNARMED_HELICOPTER    = 3
FORCE_INFO_CATAGORY_ARMED_ROUTED_VEHICLE  = 4
FORCE_INFO_CATAGORY_UNARMED_ROUTED_VEHICLE= 5
FORCE_INFO_CATAGORY_ARMED_SHIP_VEHICLE    = 6
FORCE_INFO_CATAGORY_UNARMED_SHIP_VEHICLE  = 7
NUM_FORCE_INFO_CATAGORIES                 = 8
```
Name strings: eech `aphavoc/source/entity/system/en_types/en_force.c:169-181`. Network width: `NUM_FORCE_INFO_CATAGORY_BITS = 5` (eech `aphavoc/source/entity/system/en_funcs/en_int.h:421`).

Every aircraft type carries a static `force_info_catagory` in `aircraft_database` (e.g. eech `aphavoc/source/entity/mobile/aircraft/ac_dbase.c:113` and per-type entries throughout), every vehicle in `vehicle_database` (`vh_dbase.c`). Read at runtime via `INT_TYPE_FORCE_INFO_CATAGORY` (aircraft: eech `aphavoc/source/entity/mobile/aircraft/ac_int.c:596-602` returns `aircraft_database[sub_type].force_info_catagory`; vehicles: `aphavoc/source/entity/mobile/vehicle/vh_int.c:543`). PERSON entities are excluded from the census (call commented out, eech `aphavoc/source/entity/mobile/vehicle/person/ps_creat.c:313`).

### 2.3 Sides — eech `aphavoc/source/entity/system/en_types/en_side.h:69-71,87,101`

`ENTITY_SIDE_NEUTRAL (0), ENTITY_SIDE_BLUE_FORCE (1), ENTITY_SIDE_RED_FORCE (2)`; `ENTITY_SIDE_UNINITIALISED = NUM_ENTITY_SIDES`. `get_enemy_side(SIDE)` is a strict two-side macro: `((SIDE)==BLUE) ? RED : BLUE` (en_side.h:101). Distinguish from `ENTITY_FORCES` (`AIR/GROUND/SEA`, eech `aphavoc/source/entity/system/en_types/en_force.h:110-117`), which selects a registry domain, not a faction.

### 2.4 Campaign criteria structs (dead model) — eech `aphavoc/source/entity/system/en_types/en_force.h`

- `CAMPAIGN_CRITERIA_TYPE` (en_force.h:149-198): `criteria_type`, `valid`, `result` (short ints); `rank_points`, `experience_points`, `*rank_variable`, `*experience_variable`; a union of `{goal, count, type}` / `{days, hours, minutes, seconds}` / `{value1..value4}`; `next` pointer (singly-linked list per force).
- `CAMPAIGN_RESULT_TYPES` (en_force.h:128-138): `NONE, FAIL, SUCCESS, STALEMATE, OUTOFHARDWARE, SERVER_REJECTED`. `STALEMATE` and `SERVER_REJECTED` appear only in commented code (eech `aphavoc/source/comms/comm_man.c:2472`, `aphavoc/source/ui_menu/dedicate/dedi_sc.c:257`); `OUTOFHARDWARE` is never used.
- `CAMPAIGN_TRIGGER` (en_force.h:206-229): 17 trigger types (`BALANCE_OF_POWER, TASK_COMPLETED, TASK_FAILED, OBJECT_DESTROYED, OBJECT_FIRED, OBJECT_TARGETED, OBJECT_LANDED, INEFFICIENT_KEYSITE, WAYPOINT_REACHED, SECTOR_WON, SECTOR_LOST, SECTOR_REACHED, TIME_DURATION, VARIABLE_CONDITION, RANDOM, USER_LANDED, KEY_PRESS` plus `NONE`). The dead `add_force_campaign_critiera` takes a `campaign_trigger` as its criteria type (eech `aphavoc/source/entity/special/force/force.c:124`), i.e. criteria types and triggers shared a value space. `CAMPAIGN_TRIGGER_TYPE`, `CAMPAIGN_EVENT_TYPE`, `CAMPAIGN_WHILE_LOOP_TYPE` (en_force.h:288-366) are vestiges of a scripted-event system with no live users.
- The `CAMPAIGN_CRITERIA_*` enum itself is **not defined anywhere in the tree**; its members are referenced only from commented code. Entity comms carries vestigial `INT_TYPE_CAMPAIGN_CRITERIA_COUNT/RESULT/TYPE/VALUE` slots (eech `aphavoc/source/entity/system/en_funcs/en_int.h:86-89`, bit widths :393-396); the COUNT slot is nowadays repurposed to pack sector `keysite_count` (eech `aphavoc/source/entity/special/sector/sc_pack.c:285,405`).

### 2.5 Live win-condition model — eech `aphavoc/source/ui_menu/ingame/campaign/campaign.h:98-108`

`CAMPAIGN_COMPLETED_TYPES`: `CAMPAIGN_COMPLETED_FALSE (0), CAMPAIGN_COMPLETED_OBJECTIVES (1), CAMPAIGN_COMPLETED_VALID_GUNSHIPS (2)`.

### 2.6 Task generation stats — eech `aphavoc/source/entity/system/en_types/en_force.h:240-252`

`TASK_GENERATION_TYPE`: `valid : 1`, `created`, `completed`, `failed`. (The legacy parser.c writes `.duration/.frequency/.urgency` fields that no longer exist — further proof parser.c is out of build.)

## 3. Features

### FORCE-F1 — Force entity creation & defaults
One FORCE entity per side, child of SESSION on `LIST_TYPE_FORCE` and of the update entity on `LIST_TYPE_UPDATE`.
- Defaults at create (eech `aphavoc/source/entity/special/force/fc_creat.c:130-175`): struct zeroed; `side = ENTITY_SIDE_UNINITIALISED` (must be supplied, ASSERT at :159); `force_attitude = ENTITY_FORCE_ATTITUDE_NORMAL` (:134); all `task_generation[].valid = TRUE` (:136-139); `force_name = entity_side_short_names[side]` (:167); global flag `set_force_hardware_update(TRUE)` (:169); all reserves zeroed (:171-175).
- Force lookup by side scans SESSION's force children (eech `aphavoc/source/entity/special/force/force.c:89-118`).
- Attitude values: `COWARD..ERRATIC`, 8 values (eech `aphavoc/source/entity/system/en_types/en_force.h:88-99`); parsed per faction from the warzone `FACTION` tag along with side and colour (DATA-DRIVEN; reader eech `aphavoc/source/ai/parser/parsgen.c` `FILE_TAG_FACTION` case, ~:1450ff).

| Constant | Value | Source |
|---|---|---|
| default force attitude | `ENTITY_FORCE_ATTITUDE_NORMAL` | eech `entity/special/force/fc_creat.c:134` |
| task generation default valid | TRUE (all task types) | eech `entity/special/force/fc_creat.c:136-139` |

### FORCE-F2 — Hardware categorisation
Every mobile entity maps to exactly one of the 8 `FORCE_INFO_CATAGORIES` via its type database entry (see §2.2). Armed vs unarmed and fixed-wing/helicopter/routed-vehicle/ship split. Persons are uncategorised (excluded from census).

### FORCE-F3 — Live hardware census (`force_info_current_hardware`)
- Increment on entity creation: `add_to_force_info` (eech `aphavoc/source/entity/special/force/force.c:211-243`) — `current_hardware[catagory]++` (:236). Called from every mobile create: fixed-wing eech `entity/mobile/aircraft/fixwing/fw_creat.c:308`, helicopter `helicop/hc_creat.c:346`, anti-air `vehicle/anti_air/aa_creat.c:317`, routed vehicle `vehicle/routed/rv_creat.c:321`, ship `vehicle/ship/sh_creat.c:320`, plus client-side unpack paths (`hc_pack.c:506,674`, `fw_pack.c:242`, `rv_pack.c:318`, `sh_pack.c:240`).
- Gated by the global `force_hardware_update` flag (:226-230; only ever set TRUE, at fc_creat.c:169 — effectively always on after the first force is created).
- Decrement on kill: `remove_from_force_info` (force.c:249-271) — server only (:260-264), `current_hardware[catagory]--` (:270), and records the loss (`add_mobile_to_force_losses_stats`, :258). Called from every mobile `kill_local`: `fw_dstry.c:347`, `hc_dstry.c:358`, `aa_dstry.c:339`, `rv_dstry.c:345`, `sh_dstry.c:348`.
- Trigger/cadence: purely event-driven (create/kill), no periodic recount.

### FORCE-F4 — Reserve seeding (DATA-DRIVEN)
Initial reserve pools come from the warzone faction file's `HARDWARE_RESERVES` block: repeated `TYPE <catagory-name> COUNT <int>` pairs, stored as `force_info_reserve_hardware[hardware_type] = count`.
- LIVE reader: eech `aphavoc/source/ai/parser/parsgen.c:1397-1435` (assignment at :1426). Values are warzone data, not source constants — DATA-DRIVEN.
- The prompt-referenced legacy copy is eech `aphavoc/source/ai/faction/parser.c:1271-1313` (assignment at :1303) — identical logic, but that file is **not compiled** (see §1).
- Reserves default to 0 for any category not listed (fc_creat.c:171-175).

### FORCE-F5 — Reserve consumption on runtime spawn
Inside `add_to_force_info` (F3): `if (get_game_status () == GAME_STATUS_INITIALISED) { force_info_reserve_hardware[index]--; }` (eech `aphavoc/source/entity/special/force/force.c:238-242`).
- Consequence: entities created during warzone setup (game not yet INITIALISED) populate the census **without** consuming reserves; every spawn after the campaign is running (i.e. regenerated units) consumes one reserve of its category.
- Reserves can go negative — there is no clamp in `add_to_force_info`; the only guard is regen's pre-check (F7).

### FORCE-F6 — Reserve recycle (`replace_into_force_info`) — DEAD (defined, never called)
`replace_into_force_info` (eech `aphavoc/source/entity/special/force/force.c:278-300`) increments `force_info_reserve_hardware[catagory]++` server-side and logs "adding %s back into the reserves" (:297-299). **No call site exists anywhere in the tree** (verified by full-tree grep). Also `get_force_space` is declared (force.h:161) but never defined or used. In shipped EECH, hardware that lands/withdraws is never returned to the reserve pool; the pool only ever shrinks.

### FORCE-F7 — Reserve-gated regeneration (consumer)
The regen system refuses to respawn a queued unit unless its category has reserve stock:
- `reserve_count = force_raw->force_info_reserve_hardware[aircraft_database[e1->sub_type].force_info_catagory]` for FIXED_WING/HELICOPTER, else `vehicle_database[...]` (eech `aphavoc/source/entity/special/regen/rg_updt.c:285-292`).
- `if (reserve_count <= 0) return NULL;` (rg_updt.c:294-297) — the unit stays queued indefinitely.
- On successful regen the created entity's `add_to_force_info` performs the actual decrement (F5). Post-create debug logging of remaining reserves at rg_updt.c:523-536. (Full regen behaviour — queues, keysite usability, player-landed lockout — belongs to the regen spec.)

### FORCE-F8 — `force_percentage` (balance of power) computation — DEAD CODE
From the commented server update (eech `aphavoc/source/entity/special/force/fc_updt.c:136-168`):
```
total_forces = Σ over all 8 categories of (own current_hardware[c] + enemy current_hardware[c])
this_force   = Σ over all 8 categories of own current_hardware[c]
force_percentage = (total_forces != 0) ? this_force / total_forces : 0.0
```
(loop over `FORCE_INFO_CATAGORY_ARMED_FIXED_WING .. NUM_FORCE_INFO_CATAGORIES`, i.e. all categories, :148-154). The result was pushed to clients as `FLOAT_TYPE_FORCE_PERCENTAGE` when changed (:164-168). Note this is a **live-census** ratio — reserves are not included. No live equivalent exists in the community build; the closest live analogue is the campaign-stats UI which draws per-group-type and sector balance bars from `group_count` and `sector_count` (eech `aphavoc/source/ui_menu/ingame/campaign/ca_stat.c:690-731`).

### FORCE-F9 — Campaign criteria evaluation engine — DEAD CODE
All from eech `aphavoc/source/entity/special/force/fc_updt.c` (entire body commented, :86-495). Registered as the FORCE server update at :504 — so the live function is called every entity-update tick but does nothing.
- Cadence: `raw->sleep -= get_delta_time (); if (raw->sleep <= 0.0) { raw->sleep = CAMPAIGN_COMPLETION_TIMER; ... }` with `CAMPAIGN_COMPLETION_TIMER = 5` seconds (fc_updt.c:74, :125-134).
- Semantics (header comment fc_updt.c:66-67): "all success criteria must be met for the campaign to be completed successfully. Any failures and the campaign will be failed instantly."
- Walks the force's `campaign_criteria` list (:176-417). Each criterion has `result` = the campaign outcome it produces when met (`CAMPAIGN_CRITERIA_RESULT_SUCCESS` or `..._FAIL`).
- `success_required_count` = number of criteria in the list whose `result == SUCCESS` (:181-185); `success_achieved_count` incremented per met success criterion.
- A met criterion sets `campaign_status = criteria->result` unless status is already FAIL (:196-204, :265-274). If any criterion evaluates to FAIL the loop breaks immediately (:410-414).
- After the loop: if `campaign_status == SUCCESS` but `success_achieved_count < success_required_count`, status reverts to NONE (:423-431) — i.e. **all** success criteria must be simultaneously met, but **any single** fail criterion loses instantly.
- On SUCCESS: award `experience_points` into `*experience_variable` and `rank_points` into `*rank_variable` if wired (:438-460); `inc_player_log_successful_tours` (:466). On FAIL: `inc_player_log_failed_tours` (:476). Either way: `setup_campaign_over_screen (en, campaign_status)`, `start_game_exit (GAME_EXIT_KICKOUT, FALSE)`, `push_ui_screen (campaign_over_screen)` (:489-493).
- Unknown criteria types hit `debug_fatal` (:399-403).

Criteria definitions were parsed per force from the warzone file `CAMPAIGN_CRITERIA` block (`CRITERIA <name> <fields...> RESULT <result-name>`, optional `EXPERIENCE_POINTS <n> VARIABLE <name>` and `RANK_POINTS <n> VARIABLE <name>`), legacy reader eech `aphavoc/source/ai/faction/parser.c:948-1214` (commented; file not compiled). All goals/thresholds were therefore DATA-DRIVEN per warzone. Criterion list built by `add_force_campaign_critiera` (commented, eech `aphavoc/source/entity/special/force/force.c:123-168`; `valid` defaulted TRUE at :142).

### FORCE-F10..F24 — The full criteria set (all DEAD CODE)

Fifteen named criteria appear in the source (13 evaluated in fc_updt.c; 2 parse-only). Per-criterion detail — evaluation from eech `fc_updt.c`, parse fields from eech `parser.c` (both dead):

**FORCE-F10 — CAMPAIGN_CRITERIA_BALANCE_OF_POWER** (fc_updt.c:190-226; parser.c:1001-1013)
- Parse: `GOAL <int>` (percent), `RESULT`.
- Evaluate: `count = (int)(force_percentage * 100.0)` (:193, from F8); met when `count >= goal` (:196). **Not gated by `valid`** — unlike every other counter criterion.

**FORCE-F11 — CAMPAIGN_CRITERIA_CAPTURED_SECTORS** (fc_updt.c:227-249; parser.c:1152-1165)
- Parse: `GOAL <int>`, `RESULT`.
- Evaluate: first computes and publishes `objective_sectors_percentage = (goal != 0) ? count / goal : 1.0` plus `INT_TYPE_OBJECTIVE_SECTORS_HELD` (= count) and `INT_TYPE_OBJECTIVE_SECTORS_REQUIRED` (= goal) (:230-246), then **intentional fall-through** (comment :248) into the generic check: met when `valid && count >= goal`.
- No live updater of `count` survives anywhere (see F25 / Open questions).

**FORCE-F12 — CAMPAIGN_CRITERIA_LOST_SECTORS** (fc_updt.c:255; parser.c:1152-1165)
- Parse: `GOAL <int>`, `RESULT`. Evaluate: generic — met when `valid && count >= goal` (fc_updt.c:262-296). No count updater survives.

**FORCE-F13 — CAMPAIGN_CRITERIA_COMPLETED_TASKS** (fc_updt.c:250; parser.c:1015-1032)
- Parse: `GOAL <int>`, `TYPE <task sub-type name>` (stored in union `type`), `RESULT`. Evaluate: generic `valid && count >= goal`. No count updater survives (live task-completion stats go to `task_generation[].completed` instead, F29).

**FORCE-F14 — CAMPAIGN_CRITERIA_FAILED_TASKS** (fc_updt.c:254; parser.c:1015-1032)
- Same shape as F13 (`GOAL`, task `TYPE`, `RESULT`); generic evaluation. No updater survives.

**FORCE-F15 — CAMPAIGN_CRITERIA_DESTROYED_ALLIED_OBJECTS** (fc_updt.c:251; parser.c:1034-1051)
- Parse: `GOAL <int>`, `TYPE <3D-object shape name>` (`object_3d_enumeration_names`, `OBJECT_3D_LAST` = wildcard), `RESULT` (typically FAIL — lose if you lose too many of X).
- Count updater (commented): `ENTITY_MESSAGE_FORCE_DESTROYED` handler — if victim side == force side, `criteria = DESTROYED_ALLIED_OBJECTS`, look up by shape sub_type with `OBJECT_3D_LAST` fallback, `count++` (eech `aphavoc/source/entity/special/force/fc_msgs.c:548-573`).
- Evaluate: generic `valid && count >= goal`.

**FORCE-F16 — CAMPAIGN_CRITERIA_DESTROYED_ENEMY_OBJECTS** (fc_updt.c:252; parser.c:1034-1051)
- Mirror of F15 for victims on the enemy side (fc_msgs.c:548-573). Generic evaluation.

**FORCE-F17 — CAMPAIGN_CRITERIA_ENEMY_FIRED** (fc_updt.c:253; parser.c:1167-1180)
- Parse: `GOAL <int>`, `RESULT`. Generic evaluation. No count updater survives (the live `ENTITY_MESSAGE_ENTITY_FIRED_AT` force handler only forwards to the victim's group, fc_msgs.c:317-349).

**FORCE-F18 — CAMPAIGN_CRITERIA_REACHED_WAYPOINTS** (fc_updt.c:256; parser.c:1108-1124)
- Parse: `GOAL <int>`, `TYPE <waypoint sub-type name>`, `RESULT`.
- Count updater (commented): `ENTITY_MESSAGE_FORCE_WAYPOINT_REACHED` handler, matched by waypoint sub-type, `count++` (fc_msgs.c:996-1004). Generic evaluation.

**FORCE-F19 — CAMPAIGN_CRITERIA_SECTOR_REACHED** (fc_updt.c:257; parser.c:1086-1106)
- Parse: `GOAL <int>`, `X_SECTOR <int>` (value3), `Z_SECTOR <int>` (value4), `RESULT`. Generic evaluation. No count updater survives (the live `FORCE_ENTERED_SECTOR` handler is log-only, fc_msgs.c:582-607).

**FORCE-F20 — CAMPAIGN_CRITERIA_SPECIAL_KILLS** (fc_updt.c:258)
- **No parser case exists** (not even in the dead parser) — presumably injected programmatically in the original game.
- Count updater (commented): `ENTITY_MESSAGE_FORCE_SPECIAL_KILL` handler: `count = max (count, aggressor_kills)` — a high-water mark of one aggressor's kill tally, not a sum (fc_msgs.c:924-933; kills arg :917). Generic evaluation.

**FORCE-F21 — CAMPAIGN_CRITERIA_SURRENDERED_SIDES** (fc_updt.c:259; parser.c:1072-1084)
- Parse: `GOAL <int>`, `RESULT`. Generic evaluation. No updater and no surrender mechanic survives anywhere.

**FORCE-F22 — CAMPAIGN_CRITERIA_TIME_DURATION** (fc_updt.c:298-397; parser.c:1126-1150)
- Parse: `DAYS <int>`, `HOURS <int>`, `MINUTES <int>`, `SECONDS <int>` (union fields), `RESULT`.
- Side computation `time_percentage` (:319-342): `this_time = get_time_of_day (hours, minutes, seconds)`; if `result == SUCCESS`: `time_percentage = elapsed ? this_time / session->elapsed_time_of_day : 0.0`; else (FAIL timer): `time_percentage = elapsed ? 1.0 - (this_time / session->elapsed_time_of_day) : 1.0`.
- Met when, cumulatively: `session->elapsed_days >= days && elapsed_hours >= hours && elapsed_minutes >= minutes && elapsed_seconds >= seconds` (:361-393; nested `>=` on each clock unit independently — see Open questions for the rollover quirk). Gated by `valid` (:310).
- Source comment at :381-383: "DEBUG - SHOULD THIS JUST BE SUCCESS REGARDLESS OF OTHER CRITERIA ?????" — even the original authors were unsure whether a success-timer should bypass the all-success rule.
- UI countdown for this criterion (`display_campaign_criteria_time_remaining`) is disabled under `#if 0` (eech `aphavoc/source/entity/special/force/force.c:417-562`, `#if 0` at :419); it displayed T-MM:SS in the final hour, flashing under 10 s, for GAME_TYPE_SPECIAL/MAGAZINE_DEMO only.

**FORCE-F23 — CAMPAIGN_CRITERIA_INEFFICIENT_ALLIED_KEYSITES** (parser.c:1053-1070; **no fc_updt.c case**)
- Parse: `GOAL <int>`, `TYPE <keysite sub-type name>`, `RESULT`.
- Count updater (commented): `ENTITY_MESSAGE_FORCE_INEFFICIENT_KEYSITE` handler, `count++`, allied vs enemy chosen by sender side (fc_msgs.c:635-654).
- Not handled by the fc_updt.c switch — had one been configured, evaluation would hit the `debug_fatal` default (:399-403). Dead in the parser AND unevaluatable.

**FORCE-F24 — CAMPAIGN_CRITERIA_INEFFICIENT_ENEMY_KEYSITES** (parser.c:1053-1070)
- Mirror of F23. Same parse shape, same missing evaluation case.

Common to F11-F19, F21-F24: evaluation is the generic block `if (valid && count >= goal)` at fc_updt.c:250-296. Per-criterion `RESULT` decides whether meeting it wins or loses the campaign; thresholds (`goal`) are DATA-DRIVEN from the warzone file (dead reader parser.c:948-1214).

### FORCE-F25 — Criteria count-update hooks — DEAD CODE
The force message handlers that fed criteria counters are all live functions whose criteria-updating cores are commented out:

| Message | Criterion fed | Update rule | Source (commented core) |
|---|---|---|---|
| `FORCE_DESTROYED` | DESTROYED_ALLIED/ENEMY_OBJECTS | `count++`, keyed by 3D shape, wildcard fallback | eech `entity/special/force/fc_msgs.c:548-573` |
| `FORCE_INEFFICIENT_KEYSITE` | INEFFICIENT_ALLIED/ENEMY_KEYSITES | `count++` | fc_msgs.c:635-654 |
| `FORCE_SPECIAL_KILL` | SPECIAL_KILLS | `count = max(count, kills)` | fc_msgs.c:924-933 |
| `FORCE_WAYPOINT_REACHED` | REACHED_WAYPOINTS | `count++` by waypoint sub-type | fc_msgs.c:996-1004 |

No updater for CAPTURED_SECTORS, LOST_SECTORS, COMPLETED_TASKS, FAILED_TASKS, ENEMY_FIRED, SURRENDERED_SIDES, or SECTOR_REACHED exists even in commented form — those hooks were lost entirely.

### FORCE-F26 — LIVE win check: keysite campaign objectives
`response_to_check_campaign_objectives` (eech `aphavoc/source/entity/special/force/fc_msgs.c:144-311`), server only (:161), no-op once `INT_TYPE_SESSION_COMPLETE` is set (:163-166). Check 1 (:180-216): walk this force's `LIST_TYPE_CAMPAIGN_OBJECTIVE` keysites; the force has "completed objectives" iff **every** objective keysite is either
- a troop-insertion target (`keysite_database[sub_type].troop_insertion_target`, eech `entity/special/keysite/ks_dbase.h:104`) now owned by this force's side (:190-198), or
- a non-troop-target keysite that is dead (`!INT_TYPE_ALIVE`, :199-207).
If satisfied → `complete = CAMPAIGN_COMPLETED_OBJECTIVES`.

### FORCE-F27 — LIVE win check: enemy airbase exhaustion
Same handler, check 2 (fc_msgs.c:222-249), only reached if check 1 failed: walk the **enemy** force's keysites; if no enemy keysite with `air_force_capacity != KEYSITE_AIR_FORCE_CAPACITY_NONE` (:232) is both alive and in use (`INT_TYPE_ALIVE && INT_TYPE_IN_USE`, :234) → `complete = CAMPAIGN_COMPLETED_OBJECTIVES` ("Side X Has No Keysites Left", :247).

### FORCE-F28 — LIVE win check: enemy gunship exhaustion
Same handler, check 3 (fc_msgs.c:255-295), only reached if 1 and 2 failed: walk the enemy force's `LIST_TYPE_AIR_REGISTRY` helicopter groups; if no surviving member is `aircraft_database[sub_type].player_controllable` with `view_category == VIEW_CATEGORY_COMBAT_HELICOPTERS` (:273-275) → `complete = CAMPAIGN_COMPLETED_VALID_GUNSHIPS` ("Insufficient Resources Left For Conflict"). If any check passed, `campaign_completed (side, complete)` is called (:307).

### FORCE-F29 — Live win-check triggers (event-driven cadence)
`ENTITY_MESSAGE_CHECK_CAMPAIGN_OBJECTIVES` is sent to **both** forces (loop over session force children) on:
1. Keysite capture (eech `entity/special/keysite/keysite.c:1437-1444`),
2. Keysite destruction (eech `entity/special/keysite/ks_dstry.c:358-371`),
3. Helicopter kill, server side (eech `entity/mobile/aircraft/helicop/hc_dstry.c:631-643`).
There is no periodic poll; the live win condition is purely event-driven.

### FORCE-F30 — `campaign_completed` outcome handling
eech `aphavoc/source/ui_menu/ingame/campaign/campaign.c:1096-1147`. Server: logs "CAMPAIGN WON BY %s SIDE" (:1104-1108), transmits `ENTITY_COMMS_CAMPAIGN_COMPLETED` to clients (:1114), and for GAME_TYPE_CAMPAIGN awards the campaign medal (`INT_TYPE_CAMPAIGN_MEDAL` from the session) plus a successful tour if the player's side won, else a failed tour (:1124-1136). All machines: `INT_TYPE_SESSION_COMPLETE = complete` on the session (:1145) and the campaign-completed dialog is shown (:1147; victory/defeat text and reason strings at :1029-1082). Unlike the dead criteria path, the live path does **not** kick the player out of the game.

### FORCE-F31 — Campaign objective selection at campaign start
`setup_campaign` → `create_force_campaign_objectives` per force (eech `aphavoc/source/ai/highlevl/setup.c:91-286`), called once from gameflow at campaign start (eech `aphavoc/source/gameflow/gameflow.c:891`).
- Candidates: enemy keysites with `INT_TYPE_POTENTIAL_CAMPAIGN_OBJECTIVE` (static DB flag `keysite_database[sub_type].campaign_objective`, eech `entity/special/keysite/ks_int.c:341-345`) that are `INT_TYPE_IN_USE` (setup.c:167-172, 211-213). Zero candidates is fatal (:182-185).
- Rating: distance to the closest friendly keysite within search (via `get_closest_keysite`, 1 km granularity arg, :224-226), normalised by the maximum (:244-253), plus `frand1 ()` random factor (:255-262 — "obligatory random factor").
- Sorted descending; the top `NUMBER_OF_CAMPAIGN_OBJECTIVES_PER_SIDE` are linked into the force's `LIST_TYPE_CAMPAIGN_OBJECTIVE` (:264-283).

| Constant | Value | Source |
|---|---|---|
| `NUMBER_OF_CAMPAIGN_OBJECTIVES_PER_SIDE` | 5 | eech `ai/highlevl/setup.c:79` |
| candidate keysite range granularity | 1.0 * KILOMETRE | eech `ai/highlevl/setup.c:226` |

### FORCE-F32 — Sector ownership count (`sector_count`)
`update_sector_side_count` (eech `aphavoc/source/entity/special/sector/sector.c:579-616`) recounts `INT_TYPE_SECTOR_SIDE` over the whole sector grid and stores per-side totals into each force's `INT_TYPE_FORCE_SECTOR_COUNT` (:613; accessor eech `entity/special/force/fc_int.c:111,220`, 16-bit net width en_int.h:422).
- Cadence: registered as a high-level AI function every `1.0 * ONE_MINUTE` with 15 s offset (eech `aphavoc/source/ai/highlevl/highlevl.c:282`); also run on client comms resync (eech `entity/system/en_comms/en_comms.c:5549`).
- Consumers: campaign-stats UI sector balance bars (eech `ui_menu/ingame/campaign/ca_stat.c:723-731`). Nothing in the live build wins/loses on sector count.

### FORCE-F33 — Kills / losses statistics
`add_mobile_to_force_kills_stats` / `add_mobile_to_force_losses_stats` (eech `aphavoc/source/entity/special/force/force.c:307-361`): indexed by the **victim's group sub-type**, `kills[group_sub_type]++` on the killer's force, `losses[...]++` on the victim's force (losses invoked from `remove_from_force_info`, force.c:258). Replicated to clients (fc_pack.c:257-258, 360-361).

### FORCE-F34 — Group count registry
`add_group_type_to_force_info` / `remove_group_type_from_force_info` / `get_local_force_entity_group_count` (force.c:367-411): live count of groups per group sub-type. `group_count` is deliberately NOT network-packed (commented pack lines, eech `entity/special/force/fc_pack.c:259,362,521,637`). Consumer: campaign-stats balance-of-power bars per unit class (helicopters, AA, armour aggregation of PRIMARY/SECONDARY_FRONTLINE + SP artillery + SP MLRS, eech `ui_menu/ingame/campaign/ca_stat.c:690-718`).

### FORCE-F35 — Task-generation statistics & validity gate
- `task_generation[sub_type].valid` parsed per task type from the warzone `TASK_GENERATION` block (`TYPE <name> <0|1>`, DATA-DRIVEN; reader eech `aphavoc/source/ai/parser/parsgen.c:1350-1394`, assignment :1385); default TRUE (fc_creat.c:138). Gates whether the task generator may create that task type (eech `ai/taskgen/taskgen.c:2423`).
- `created` incremented on task creation (taskgen.c:209; also used as task id seed :303). `completed`/`failed` incremented in the force's `TASK_COMPLETED` message handler by `INT_TYPE_TASK_COMPLETED == TASK_COMPLETED_FAILURE` (eech `entity/special/force/fc_msgs.c:1275-1327`, failed++ :1320, completed++ :1324; also spawns reactionary tasks :1308).

### FORCE-F36 — Force state replication
`fc_pack.c` packs per force (server→client): list roots incl. campaign objectives (:185/288), task_generation valid+created (:201-203), `force_info_current_hardware` and `force_info_reserve_hardware` per category (:249-251 initial, :352-354 update), kills/losses (:257-258/360-361), `sector_count` (:369), side/colour/attitude. Unpack mirrors at :448-644. Clients therefore see reserves and census read-only; all mutation is server-side (force.c:260-264, :287-291).

### FORCE-F37 — Force update cadence (live no-op)
The FORCE server update is dispatched from the entity update list every update iteration (eech `entity/special/update/up_update.c:171-181`; force inserted into the update list at fc_creat.c:185). The registered function `update_server` (fc_updt.c:502-505) has a fully commented body, so per-tick force work in the community build is nil. The designed cadence for criteria checks was the 5 s sleep timer (F9).

## 4. Interactions

- **Regen (rg_updt.c)**: sole consumer of reserves besides seeding — reserve gate at rg_updt.c:285-297 (F7); each regen spawn re-enters the census and decrements reserve via `add_to_force_info` (F3/F5). Regen frequency itself is a warzone `REGEN_FREQUENCY` tag (parsgen.c) — regen spec territory.
- **Keysites**: force keysite list (`keysite_force_root`) feeds live win checks F26/F27; keysite capture/destroy events trigger the win check (F29); `keysite_database` flags (`campaign_objective`, `troop_insertion_target`, `air_force_capacity`) parameterise objective selection and win tests.
- **Sectors**: sector side flips drive `sector_count` (F32); the dead CAPTURED_SECTORS/LOST_SECTORS criteria were meant to consume this domain.
- **Task generator (taskgen.c)**: reads `task_generation[].valid` gate and writes created/completed/failed (F35); the dead COMPLETED_TASKS/FAILED_TASKS criteria would have consumed the same events.
- **Session**: `INT_TYPE_SESSION_COMPLETE` freezes further win checks (fc_msgs.c:163) and drives end-of-campaign UI; elapsed time (`elapsed_time_of_day`, `elapsed_days`) fed the dead TIME_DURATION criterion.
- **Player log / medals**: win path awards tours and campaign medal (F30); dead criteria path awarded experience/rank points (F9).
- **UI**: campaign stats screen draws balance-of-power bars from `group_count` and `sector_count` (ca_stat.c:690-731); map highlights objective keysites via `LIST_TYPE_CAMPAIGN_OBJECTIVE` parent (eech `ui_menu/ingame/common/map.c:1381,2933`). In-flight debug overlay prints current vs reserve per category (eech `aphavoc/source/test.c:829-914`).
- **Supply**: `FORCE_LOW_ON_SUPPLIES` message handler on the force creates resupply tasks (fc_msgs.c:672ff) — supply spec territory, but it is force-entity behaviour.

## 5. Port mapping

(Assessed only against the stated port summary: campaign_state with live-census strength + early/mid/late phases; supply as finite per-side role pools with consume-on-spawn / recycle-on-RTB, no production; win_condition with exactly 3 criteria — captured sectors, balance of power, 4 h time limit; regen reserve-gated per rg_updt.c:287, aircraft only; NOT ported: other criteria, persistence, population, divisions.)

| Feature | Status | Note |
|---|---|---|
| F1 force entity/defaults | PARTIAL (campaign_state) | Port keeps per-side state; attitude/name/list-roots presumably dropped. |
| F2 hardware categories | PROXY (supply) | Port uses "role pools" rather than the 8 armed/unarmed domain categories. |
| F3 live census | PORTED (campaign_state) | Port strength = live census per fc_updt.c force_percentage inputs. |
| F4 reserve seeding | PORTED (supply) | Finite per-side pools; EECH values are warzone DATA-DRIVEN (parsgen.c:1426). |
| F5 consume-on-spawn | PORTED (supply) | Matches EECH's reserve-- on runtime spawn (force.c:241). |
| F6 recycle to reserve | PROXY (supply) | Port recycles on RTB; in EECH `replace_into_force_info` exists but is NEVER called — shipped EECH never recycles. Port implements the intent, not the shipped behaviour. |
| F7 regen reserve gate | PORTED (regen) | Per rg_updt.c:287; port restricts to aircraft only (EECH gates vehicles too, rg_updt.c:291) → PARTIAL on scope. |
| F8 force_percentage | PORTED (campaign_state / win_condition) | Port's balance-of-power strength ratio; note EECH formula is dead code. |
| F9 criteria engine (all-success/any-fail, 5 s cadence) | PARTIAL | Port has a win_condition evaluator but only 3 criteria; EECH's success-count/fail-fast semantics and per-criterion RESULT polarity presumably simplified. UNKNOWN whether 5 s cadence matched. |
| F10 BALANCE_OF_POWER | PORTED (win_condition) | One of the port's 3 criteria. |
| F11 CAPTURED_SECTORS | PORTED (win_condition) | One of the port's 3 criteria (EECH count updater is lost even in dead code). |
| F12 LOST_SECTORS | NOT PORTED | |
| F13 COMPLETED_TASKS | NOT PORTED | |
| F14 FAILED_TASKS | NOT PORTED | |
| F15 DESTROYED_ALLIED_OBJECTS | NOT PORTED | |
| F16 DESTROYED_ENEMY_OBJECTS | NOT PORTED | |
| F17 ENEMY_FIRED | NOT PORTED | |
| F18 REACHED_WAYPOINTS | NOT PORTED | |
| F19 SECTOR_REACHED | NOT PORTED | |
| F20 SPECIAL_KILLS | NOT PORTED | |
| F21 SURRENDERED_SIDES | NOT PORTED | |
| F22 TIME_DURATION | PORTED (win_condition) | Port's 4 h time limit; EECH threshold was DATA-DRIVEN days/h/m/s per warzone. |
| F23 INEFFICIENT_ALLIED_KEYSITES | NOT PORTED | (Unevaluatable even in EECH dead code.) |
| F24 INEFFICIENT_ENEMY_KEYSITES | NOT PORTED | |
| F25 criteria count hooks | NOT PORTED | Only the 3 ported criteria need feeds. |
| F26 live keysite-objectives win | NOT PORTED | Port's win_condition uses the criteria model, not the shipped objective-keysite check. |
| F27 live airbase-exhaustion win | NOT PORTED | |
| F28 live gunship-exhaustion win | NOT PORTED | |
| F29 event-driven win triggers | NOT PORTED | Port presumably polls; EECH live check is event-driven. |
| F30 campaign_completed handling | PARTIAL | Port declares win/lose; medals/player-log/tours not applicable. |
| F31 objective selection (5/side) | NOT PORTED | No campaign-objective keysite list in port summary. |
| F32 sector_count (60 s cadence) | PARTIAL | Port counts captured sectors for win_condition; EECH's 60 s +15 s offset cadence and UI use UNKNOWN. |
| F33 kills/losses stats | UNKNOWN | Not mentioned in port summary. |
| F34 group_count registry | NOT PORTED | Population/divisions explicitly not ported. |
| F35 task_generation stats/gate | UNKNOWN | Depends on port's task generator. |
| F36 replication | NOT PORTED | DCS handles state distribution; N/A. |
| F37 update cadence | PARTIAL | Port has campaign phase ticks; EECH live force tick is a no-op. |

**Most consequential gaps:** (1) The port's 3-criteria win_condition models the *dead* Razorworks criteria system, while shipped EECH actually ends campaigns via F26-F28 (all objective keysites captured/destroyed, enemy out of usable airbases, or enemy out of player-controllable gunships) — none of which the port implements. (2) 12 of the 15 criteria are absent from the port (F12-F21, F23-F24). (3) The port's recycle-on-RTB has no shipped-EECH counterpart (F6 dead); faithful-to-shipped behaviour would be a monotonically shrinking pool.

## 6. Open questions

1. **Where were CAPTURED_SECTORS / LOST_SECTORS counts updated?** No updater exists even in commented code; the sector-capture path never touches criteria. Likely lost in the EEAH→EECH codebase transition. The port's captured-sectors criterion therefore has no exact EECH formula for *count* — only the threshold comparison (`count >= goal`) is attested.
2. **Numeric values of the `CAMPAIGN_CRITERIA_*` enum** are unrecoverable from this tree (enum deleted; only identifier names survive in comments). Ordering/values would matter only for save compatibility, which is out of scope.
3. **TIME_DURATION rollover quirk** (fc_updt.c:361-393): the check requires each clock unit *independently* ≥ its threshold, so e.g. target 01:30:00 is NOT met at elapsed 02:15:00 (minutes 15 < 30) until minutes also pass 30 within some hour. Whether the original shipped game had this bug or evaluated total elapsed seconds is unknown; a faithful port of the *letter* of the code reproduces the quirk.
4. **BALANCE_OF_POWER ignores `valid`** (fc_updt.c:190-226) while all other counter criteria are `valid`-gated — intentional or oversight?
5. **`time_percentage` formula direction** (fc_updt.c:319-342): `target_time / elapsed_time` yields >1 early and →1 as elapsed approaches target, which reads inverted for a progress value; the consumer UI is gone, so intended semantics are unverifiable.
6. **Who was meant to call `replace_into_force_info` / `get_force_space`?** No caller or definition respectively; presumably the withdrawal/landing path in the original design. The port's recycle-on-RTB is a reasonable reconstruction but is not attested in this source.
7. **fc_updt.c:382 author comment** questions whether a SUCCESS time criterion should win regardless of other criteria — the all-success rule (F9) as written says no.
8. **`success_required_count` counts criteria list entries whose `result == SUCCESS` at scan time each tick** (fc_updt.c:181-185) — since `result` on the criterion is its configured outcome (not a met/unmet state), required==configured success criteria; but `success_achieved_count` for BALANCE_OF_POWER/generic is only incremented inside the "not already FAIL" guard for BOP (:206-210) yet outside it for the generic block (:276-280) — inconsistent bookkeeping in the dead code, transcribed as-is.
