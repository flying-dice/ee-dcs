# EECH Spec 05 — Task Reactions & Follow-on Chains

Sources:
- `aphavoc/source/ai/highlevl/reaction.c` (full file, 996 lines) — all reaction logic
- `aphavoc/source/ai/highlevl/reaction.h` — public API
- `aphavoc/source/ai/highlevl/highlevl.c` — `create_sead_tasks_around_keysite` (2576), artillery caller (3091)
- `aphavoc/source/entity/special/force/fc_msgs.c` — force-level dispatch (1258, 1275)
- `aphavoc/source/entity/special/task/ts_msgs.c`, `ts_updt.c`, `task.c` — task state-change plumbing feeding the dispatch
- `aphavoc/source/ai/taskgen/assign.c`, `taskgen.c` — TASK_ASSIGNED notify origin, reaction task constructors
- `aphavoc/source/entity/special/keysite/ks_dbase.h/.c` — keysite flags consumed by reactions
- `aphavoc/source/entity/special/task/ts_dbase.c` — task priorities consumed by reactions
- `aphavoc/source/misc/msg_in.c` — Campaign Commander map-click dispatch

## 1. Overview

`reaction.c` is the campaign AI's event-driven task layer: it sits on top of the periodic high-level task generators (highlevl.c) and creates *reactionary* tasks in response to task lifecycle events, all server-side only (`ASSERT (get_comms_model () == COMMS_MODEL_SERVER)`, eech reaction.c:107, 162, 335, 627, 736).

Four entry points (eech reaction.h:67-73):

1. `create_task_assigned_reactionary_tasks (task)` — when an offensive task against a keysite is **assigned** to a group, the *owning* side of that task spawns defensive air cover (CAP / BARCAP) over the **objective keysite** if the keysite type demands it. Note: the reaction is created on the *objective's* side (`objective_side`, eech reaction.c:239), i.e. the defender protects its own keysite the moment the attacker's task is assigned (an omniscient-defender design).
2. `create_task_completed_reactionary_tasks (task)` — when a RECON/BDA or GROUND_STRIKE/OCA_STRIKE task **completes**, the tasking side spawns follow-on tasks (SEAD ring, troop insertion, OCA strike/sweep, ground strike, anti-ship strike, BDA), branched on keysite flags and current keysite efficiency. This is the core recon → strike → BDA → re-strike campaign loop, plus the defender's "backup" counter-insertion.
3. `create_reaction_to_artillery_fire (group, target)` — when an artillery group opens fire, the *victim's* side creates a BAI or RECON task against the firing group, with priority scaled by an influence-map sector rating.
4. `create_reaction_to_map_click (objective)` — Jabberwock "Campaign Commander" mod: a player map click manually triggers the recon-completed reaction set for the player's side (no recon required). Player-driven, not autonomous campaign behaviour.

There is **no dedicated task-failed reaction**: failures are filtered out inside the completed-reaction functions and only counted in force statistics (see REACT-F12).

## 2. Data model

### 2.1 Reaction entry points (eech reaction.h:67-73)
| Function | Trigger |
|---|---|
| `create_task_assigned_reactionary_tasks` | `ENTITY_MESSAGE_TASK_ASSIGNED` on FORCE (eech fc_msgs.c:1266) |
| `create_task_completed_reactionary_tasks` | `ENTITY_MESSAGE_TASK_COMPLETED` on FORCE (eech fc_msgs.c:1308) |
| `create_reaction_to_artillery_fire` | direct call from artillery tasking (eech highlevl.c:3091) |
| `create_reaction_to_map_click` | `MESSAGE_LOCAL_BASE_CAMCOM_MESSAGE` (eech msg_in.c:1160-1162) |

### 2.2 Task completion enums (eech en_task.h)
- `task_completed_types`: `TASK_INCOMPLETE`, `TASK_COMPLETED_FAILURE`, `TASK_COMPLETED_PARTIAL`, `TASK_COMPLETED_SUCCESS` (eech en_task.h:98-109).
- `task_terminated_types`: `IN_PROGRESS`, `EXPIRE_TIME_REACHED`, `ABORTED`, `GROUP_DESTROYED`, `OBJECTIVE_MESSAGE`, `STOP_TIME_REACHED`, `WAYPOINT_ROUTE_COMPLETE` (eech en_task.h:115-129).
- `INT_TYPE_TASK_COMPLETED` on the task entity holds the assessed result; set from `assess_task_completeness` (eech ts_msgs.c:313-319, task.c:94).

### 2.3 Keysite database flags consumed (struct eech ks_dbase.h:67-106; static table eech ks_dbase.c:82-507; WUT-file override reader eech wutcfg.c:495-535 — DATA-DRIVEN, bits 6-14 of a packed word remap `requires_cap`(bit 6), `requires_barcap`(7), `repairable`(8), `oca_target`(9), `recon_target`(10), `ground_strike_target`(11), `ship_strike_target`(12), `troop_insertion_target`(13), `campaign_objective`(14), eech wutcfg.c:527-535; `minimum_efficiency` via "Minimum Efficiency" key, eech wutcfg.c:509):

| Keysite sub-type | min_eff | req_cap | req_barcap | oca | recon | gnd_strike | ship_strike | troop_ins | source (ks_dbase.c) |
|---|---|---|---|---|---|---|---|---|---|
| AIRBASE | 0.3 | TRUE | FALSE | TRUE | TRUE | TRUE | FALSE | TRUE | eech ks_dbase.c:91-130 |
| ANCHORAGE (Carrier) | 0.3 | FALSE | TRUE | TRUE | TRUE | FALSE | TRUE | FALSE | eech ks_dbase.c:138-177 |
| FACTORY | 0.3 | FALSE | FALSE | FALSE | FALSE | TRUE | FALSE | TRUE | eech ks_dbase.c:185-224 |
| FARP | 0.3 | TRUE | FALSE | FALSE | TRUE | TRUE | FALSE | TRUE | eech ks_dbase.c:232-271 |
| MILITARY_BASE | 0.3 | FALSE | FALSE | FALSE | TRUE | TRUE | FALSE | TRUE | eech ks_dbase.c:279-318 |
| PORT | 0.3 | FALSE | FALSE | FALSE | FALSE | TRUE | FALSE | FALSE | eech ks_dbase.c:326-365 |
| POWER_STATION | 0.3 | FALSE | FALSE | FALSE | TRUE | TRUE | FALSE | FALSE | eech ks_dbase.c:373-412 |
| OIL_REFINERY | 0.3 | FALSE | FALSE | FALSE | TRUE | TRUE | FALSE | FALSE | eech ks_dbase.c:420-459 |
| RADIO_TRANSMITTER | 0.3 | FALSE | FALSE | FALSE | TRUE | TRUE | FALSE | FALSE | eech ks_dbase.c:467-506 |

Invariant: `repairable == troop_insertion_target` asserted at keysite creation (eech ks_creat.c:191).

### 2.4 Task database priorities consumed (`task_database[...].task_priority`, static table eech ts_dbase.c:100; float, higher = more urgent)
| Task type | priority | source |
|---|---|---|
| ANTI_SHIP_STRIKE | 7 | eech ts_dbase.c:233 |
| BAI | 4 | eech ts_dbase.c:294 |
| BARCAP | 7 | eech ts_dbase.c:355 |
| BDA | 9 | eech ts_dbase.c:416 |
| CLOSE_AIR_SUPPORT | 6 | eech ts_dbase.c:476 |
| COMBAT_AIR_PATROL | 5 | eech ts_dbase.c:597 |
| GROUND_STRIKE | 9 | eech ts_dbase.c:844 |
| OCA_STRIKE | 6 | eech ts_dbase.c:1035 |
| OCA_SWEEP | 7 | eech ts_dbase.c:1095 |
| RECON | 7 | eech ts_dbase.c:1155 |
| SEAD | 9 | eech ts_dbase.c:1335 |
| TROOP_INSERTION | 10 | eech ts_dbase.c:1706 |

### 2.5 Dedup helper
`entity_is_object_of_task (en, task_type, side)` returns the **count** of tasks of `task_type`/`side` in the entity's `LIST_TYPE_TASK_DEPENDENT` list whose `TASK_STATE != TASK_STATE_COMPLETED` (eech task.c:618-658). Most reaction gates use it as a boolean ("already tasked → skip"); the backup-insertion gate uses the count (`< 2` patrols, eech reaction.c:434).

### 2.6 Fog-of-war values consumed
- `get_sector_fog_of_war_value (sector, side)` — per-sector per-side freshness value; compared against fractions of the session's `FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE`.
- `DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE = 4.0 * ONE_HOUR` (eech highlevl.h:69); decay rate `FOG_OF_WAR_DECAY_RATE = 30.0` (eech highlevl.h:67); session value bounded to `[8*FOG_OF_WAR_DECAY_RATE, 8*ONE_HOUR]` (eech ss_creat.c:213). DATA-DRIVEN: command-line overridable (eech cmndline.c:313).

### 2.7 Time constants
`ONE_MINUTE = SECONDS_IN_A_MINUTE = 60` (eech modules/maths/constant.h:163, 145) → `30.0 * ONE_MINUTE = 1800 s`.

## 3. Features

### REACT-F1 — Trigger path (task state-change dispatch)

**Assigned path:** `assign_task_to_group` (eech assign.c:765), after pushing the task onto the group's task stack, notifies the owning FORCE with `ENTITY_MESSAGE_TASK_ASSIGNED` (eech assign.c:592). The FORCE handler `response_to_task_assigned` (registered eech fc_msgs.c:1378, body eech fc_msgs.c:1258-1269) calls `create_task_assigned_reactionary_tasks (sender)` (eech fc_msgs.c:1266) unconditionally on the server. (Members are also individually notified at eech assign.c:979, but that drives unit behaviour, not reactions.)

**Completed path:** any source may send `ENTITY_MESSAGE_TASK_COMPLETED` to the TASK entity with a `task_terminated` reason — objective-destroyed hooks in every `*_dstry.c` (`TASK_TERMINATED_OBJECTIVE_MESSAGE`, e.g. eech cb_dstry.c:265), stop-timer tick in `ts_updt.c` (`TASK_TERMINATED_STOP_TIME_REACHED`, eech ts_updt.c:159), guide/group events, keysite capture (eech keysite.c:804), etc. The TASK handler `response_to_task_completed` (eech ts_msgs.c:261-390): for a **primary** task in `TASK_STATE_ASSIGNED`, calls `assess_task_completeness` (eech ts_msgs.c:313; body eech task.c:94) which maps the terminate reason + objective damage ratios to SUCCESS/PARTIAL/FAILURE; stores it in `INT_TYPE_TASK_COMPLETED` (eech ts_msgs.c:319); then notifies the FORCE (eech ts_msgs.c:345). The FORCE handler `response_to_task_completed` (registered eech fc_msgs.c:1380, body eech fc_msgs.c:1275-1328) calls `create_task_completed_reactionary_tasks (sender)` (eech fc_msgs.c:1308) for **every** completion result (success, partial, failure); result filtering happens inside the reaction functions. `ENTITY_MESSAGE_TASK_TERMINATED` also routes into the completed handler first if the task is still `TASK_INCOMPLETE` (eech ts_msgs.c:459-461). An **unassigned** primary task receiving TASK_COMPLETED is set to `TASK_COMPLETED_FAILURE` and terminated with no reaction (eech ts_msgs.c:295-306).

| constant | value | source |
|---|---|---|
| dispatch guard | server only | eech fc_msgs.c:1264, 1286 |

Cadence: purely event-driven (no polling).

### REACT-F2 — Task-assigned reaction: defensive CAP at targeted keysite

Behavior (eech reaction.c:97-146, 217-255): when a task of type **GROUND_STRIKE, OCA_STRIKE, OCA_SWEEP, or RECON** (eech reaction.c:119-122) is assigned and its objective (`LIST_TYPE_TASK_DEPENDENT` parent, eech reaction.c:229) is a **KEYSITE** (eech reaction.c:233), then if `keysite_database[objective_type].requires_cap` (eech reaction.c:243) and the keysite is **not already the object of a live CAP task of the objective's own side** (dedup, eech reaction.c:245), the objective's side creates a CAP over the keysite via `create_cap_task (objective_side, objective, task, TRUE /*critical*/, priority=task_database[CAP].task_priority, duration=30.0*ONE_MINUTE, NULL, NULL)` (eech reaction.c:247). All other task types (BAI, BDA, CAS, COASTAL_PATROL, CAP, ESCORT, REPAIR, SEAD, SUPPLY, TRANSFER_*, TROOP_INSERTION) explicitly produce no assigned-reaction (eech reaction.c:129-144). The local `task_side` is computed but unused (eech reaction.c:109 — dead).

CAP construction detail (eech taskgen.c:784-897): 4 orbit waypoints at 8 km radius around the keysite at a random offset angle (eech taskgen.c:819-853); unassigned **expire timer 10 min** (eech taskgen.c:877); the passed `duration` (1800 s) becomes the assigned-state **stop timer** — when it runs out, `ts_updt.c` fires TASK_COMPLETED with STOP_TIME_REACHED (eech ts_updt.c:145-160), which for CAP/BARCAP assesses as SUCCESS (eech task.c:183-205), sending the flight home (guide notify, eech ts_msgs.c:363-370).

| constant | value | source |
|---|---|---|
| triggering task types | GROUND_STRIKE, OCA_STRIKE, OCA_SWEEP, RECON | eech reaction.c:119-122 |
| gate | `requires_cap` flag | eech reaction.c:243 |
| dedup | no live CAP (objective side) on keysite | eech reaction.c:245 |
| priority | task_database[CAP] = 5 | eech reaction.c:247, ts_dbase.c:597 |
| on-station duration (stop timer) | 30.0 * ONE_MINUTE = 1800 s | eech reaction.c:247 |
| critical flag | TRUE | eech reaction.c:247 |
| CAP orbit radius | 8 km, 4 waypoints | eech taskgen.c:819 |
| unassigned expire timer | 10 * ONE_MINUTE = 600 s | eech taskgen.c:877 |

Trigger: event (task assigned). Reaction task size: not set here — flight size is decided at assignment time by the task generator/assignment system, not by reaction.c.

### REACT-F3 — Task-assigned reaction: defensive BARCAP (barrier CAP)

Behavior (eech reaction.c:257-306): same trigger set and keysite check as F2; gate is `keysite_database[objective_type].requires_barcap` (eech reaction.c:257; only ANCHORAGE/Carrier has it TRUE by default, eech ks_dbase.c:168) and dedup "no live BARCAP of objective side on this keysite" (eech reaction.c:259). The BARCAP centre position is computed **6 km from the objective toward the attacking group**: take the tasked group's position via the task's first guide → guide-stack parent group (eech reaction.c:274-282), form the normalized horizontal direction objective→group (eech reaction.c:286-290), and offset `position = objective_pos + direction * 6 km` (y = objective y) (eech reaction.c:292-296). Then `create_barcap_task (objective_side, objective, task, TRUE, &position, task_database[BARCAP].task_priority, 30.0*ONE_MINUTE, NULL, NULL)` (eech reaction.c:298). BARCAP constructor: unassigned expire timer 10 min (eech taskgen.c:690), duration → stop timer (eech taskgen.c:700).

| constant | value | source |
|---|---|---|
| gate | `requires_barcap` flag | eech reaction.c:257 |
| barrier offset distance | 6.0 * KILOMETRE | eech reaction.c:292 |
| priority | task_database[BARCAP] = 7 | eech reaction.c:298, ts_dbase.c:355 |
| on-station duration (stop timer) | 30.0 * ONE_MINUTE = 1800 s | eech reaction.c:298 |
| critical flag | TRUE | eech reaction.c:298 |
| unassigned expire timer | 10 * ONE_MINUTE = 600 s | eech taskgen.c:690 |

Formula: `dir = normalise(group_pos - objective_pos, y=0); barcap_centre = objective_pos + dir * 6000 m` (eech reaction.c:286-296).

### REACT-F4 — Recon/BDA-completed: SEAD suppression ring around keysite (gate for all keysite follow-ons)

Behavior: `create_task_completed_reactionary_tasks` routes **RECON and BDA** completions to `create_reaction_to_recon_task_completed` (eech reaction.c:170-180). Preconditions: objective side must differ from task side (eech reaction.c:353-356) and `INT_TYPE_TASK_COMPLETED == TASK_COMPLETED_SUCCESS` (strict — PARTIAL does not trigger recon follow-ons, eech reaction.c:358-361). For a KEYSITE objective, before any strike follow-on, `create_sead_tasks_around_keysite (task, objective, task_side)` runs (eech reaction.c:386); **if it created more than 1 SEAD task, all further keysite follow-ons are aborted** ("if greater than threshold abort strike and create S.E.A.D.", eech reaction.c:383-389).

`create_sead_tasks_around_keysite` (eech highlevl.c:2576-2687): iterates the **enemy** force's independent groups (eech highlevl.c:2612); for each group whose database `default_entity_type == ENTITY_TYPE_ANTI_AIRCRAFT` (eech highlevl.c:2622), alive (eech highlevl.c:2628), not already object of a live SEAD **or RECON** task of the reacting side (eech highlevl.c:2634-2635), within `MAX_KEYSITE_SEAD_RANGE` = 4 km 2-D of the keysite (eech highlevl.c:2643), and in a sector whose fog-of-war value for the reacting side exceeds `0.25 *` session FOW maximum (intel fresh enough, eech highlevl.c:2653), creates `create_sead_task (this_side, group, original_task, TRUE, priority=original task's FLOAT_TYPE_TASK_PRIORITY, NULL, NULL)` (eech highlevl.c:2610, 2659). Stops after `MAX_KEYSITE_SEAD_COUNT` = 3 (eech highlevl.c:2673-2676); returns count.

| constant | value | source |
|---|---|---|
| suppression radius | MAX_KEYSITE_SEAD_RANGE = 4.0 * KILOMETRE | eech highlevl.c:2572 |
| max SEAD tasks per reaction | MAX_KEYSITE_SEAD_COUNT = 3 | eech highlevl.c:2574 |
| abort-follow-ons threshold | SEAD count > 1 | eech reaction.c:386 |
| FOW gate | > 0.25 * FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE | eech highlevl.c:2653 |
| SEAD priority | inherits original task's priority (RECON=7 / BDA=9) | eech highlevl.c:2610, ts_dbase.c:1155/416 |
| dedup | group not object of live SEAD or RECON (reacting side) | eech highlevl.c:2634-2635 |

Also on success against a **live** keysite: a recon text message reporting the keysite usable state is sent to the force (eech reaction.c:391-400); if the keysite is dead, only a "has been destroyed" message is sent and no tasks are created (eech reaction.c:509-518; the ALIVE check wraps all keysite follow-ons, eech reaction.c:391).

### REACT-F5 — Recon-completed: troop insertion at weakened keysite (capture attempt)

Behavior (eech reaction.c:402-453): if `keysite_database[sub_type].troop_insertion_target` (eech reaction.c:402) and `efficiency < keysite_database[sub_type].minimum_efficiency` (strict `<`; efficiency from `FLOAT_TYPE_EFFICIENCY`, eech reaction.c:380, 408; min_eff = 0.3 for all stock types) and the keysite is not already object of a live **TROOP_INSERTION or TROOP_MOVEMENT_INSERT_CAPTURE** task of the attacking side (eech reaction.c:410-411), create `create_troop_insertion_task (task_side, objective, task, TRUE, task_database[TROOP_INSERTION].task_priority, NULL, NULL)` (eech reaction.c:413).

| constant | value | source |
|---|---|---|
| gate flag | `troop_insertion_target` | eech reaction.c:402 |
| efficiency threshold | efficiency < minimum_efficiency (0.3 stock) | eech reaction.c:408, ks_dbase.c:103 |
| dedup | no live TI or TM_INSERT_CAPTURE (attacker side) | eech reaction.c:410-411 |
| priority | task_database[TROOP_INSERTION] = 10 | eech reaction.c:413, ts_dbase.c:1706 |
| critical flag | TRUE | eech reaction.c:413 |

### REACT-F6 — Recon-completed: backup defender troop insertion (counter-insertion)

Behavior (eech reaction.c:427-449, nested inside F5's success branch — only runs if the attacker's TI task was actually created, `if (new_task)`, eech reaction.c:415): the **defending** (objective) side gets its own troop insertion at the same keysite to reinforce it, if ALL of:
- `objective_side != task_side` (eech reaction.c:430);
- defender has no live TROOP_INSERTION on the keysite (eech reaction.c:431);
- defender has no live TROOP_MOVEMENT_INSERT_CAPTURE (eech reaction.c:432);
- defender has no live TROOP_MOVEMENT_INSERT_DEFEND (eech reaction.c:433);
- defender has **fewer than 2** live TROOP_MOVEMENT_PATROL tasks on the keysite (count semantics of `entity_is_object_of_task`, eech reaction.c:434, task.c:618-658).

Then `create_troop_insertion_task (objective_side, objective, NULL /*no originator*/, TRUE, task_database[TROOP_INSERTION].task_priority, NULL, NULL)` (eech reaction.c:437). Logged as "BACKUP TROOP INSERTION" (eech reaction.c:441).

| constant | value | source |
|---|---|---|
| patrol-count gate | patrols < 2 | eech reaction.c:434 |
| priority | task_database[TROOP_INSERTION] = 10 | eech reaction.c:437 |
| originator | NULL (unlike attacker TI which chains from the recon task) | eech reaction.c:437 |

### REACT-F7 — Recon-completed: OCA strike + OCA sweep at OCA-target keysites

Behavior (eech reaction.c:455-480): if `keysite_database[sub_type].oca_target` (eech reaction.c:455) — **no efficiency condition** — create, independently:
- OCA STRIKE if no live OCA_STRIKE (attacker side) on the keysite: `create_oca_strike_task (task_side, objective, task, TRUE, task_database[OCA_STRIKE].task_priority, NULL, NULL)` (eech reaction.c:457-459);
- OCA SWEEP if no live OCA_SWEEP: `create_oca_sweep_task (task_side, objective, task, TRUE, task_database[OCA_SWEEP].task_priority, NULL, NULL)` (eech reaction.c:469-471).

| constant | value | source |
|---|---|---|
| gate flag | `oca_target` (stock: airbase, carrier) | eech reaction.c:455, ks_dbase.c:124/171 |
| OCA strike priority | 6 | eech reaction.c:459, ts_dbase.c:1035 |
| OCA sweep priority | 7 | eech reaction.c:471, ts_dbase.c:1095 |

### REACT-F8 — Recon-completed: ground strike at healthy keysites

Behavior (eech reaction.c:482-495): if `keysite_database[sub_type].ground_strike_target` and `efficiency >= keysite_database[sub_type].minimum_efficiency` (eech reaction.c:484), create `create_ground_strike_task (task_side, objective, task, TRUE, task_database[GROUND_STRIKE].task_priority, NULL, NULL)` (eech reaction.c:486). **No dedup check** — a ground strike is created even if one already exists (contrast F5/F7). Together with F5, `minimum_efficiency` is the branch point: efficiency < 0.3 → capture by troop insertion; ≥ 0.3 → bomb it down first.

| constant | value | source |
|---|---|---|
| gate | `ground_strike_target` AND efficiency ≥ minimum_efficiency | eech reaction.c:482-484 |
| priority | task_database[GROUND_STRIKE] = 9 | eech reaction.c:486, ts_dbase.c:844 |
| dedup | none | eech reaction.c:482-495 |

### REACT-F9 — Recon-completed: anti-ship strike

Behavior (eech reaction.c:497-507): if `keysite_database[sub_type].ship_strike_target` (stock: carrier only, eech ks_dbase.c:174), create `create_anti_ship_strike_task (task_side, objective, task, TRUE, task_database[ANTI_SHIP_STRIKE].task_priority, NULL, NULL)` (eech reaction.c:499). **No dedup and no efficiency condition** (eech reaction.c:497-507).

| constant | value | source |
|---|---|---|
| gate flag | `ship_strike_target` | eech reaction.c:497 |
| priority | task_database[ANTI_SHIP_STRIKE] = 7 | eech reaction.c:499, ts_dbase.c:233 |

### REACT-F10 — Recon-completed against GROUP objectives: SEAD (AA) or BAI (frontline)

Behavior (eech reaction.c:523-601): when the completed recon's objective is a GROUP:
- **Anti-aircraft group** (`sub_type == ENTITY_SUB_TYPE_GROUP_ANTI_AIRCRAFT`, eech reaction.c:525) with `member_count > 0` (eech reaction.c:536): if no live SEAD (attacker side) on the group, create `create_sead_task (task_side, objective, task, TRUE, task_database[SEAD].task_priority, NULL, NULL)` (eech reaction.c:538-540); send "revealed N enemy A-A installation(s)" force message (eech reaction.c:549-565).
- **Frontline group** (`group_database[sub_type].frontline_flag`, eech reaction.c:568; field eech gp_dbase.h:114) with `member_count > 0`: if no live BAI, create `create_bai_task (task_side, objective, task, TRUE, task_database[BAI].task_priority, NULL, NULL)` (eech reaction.c:581-583); send "revealed enemy armoured battalion" message (eech reaction.c:592-596).
- Any other group type: no reaction.

| constant | value | source |
|---|---|---|
| SEAD priority | 9 | eech reaction.c:540, ts_dbase.c:1335 |
| BAI priority | 4 | eech reaction.c:583, ts_dbase.c:294 |
| member gate | member_count > 0 | eech reaction.c:536, 579 |
| dedup | no live SEAD / BAI respectively (attacker side) | eech reaction.c:538, 581 |

### REACT-F11 — Strike-completed follow-on: re-strike vs BDA

Behavior: `create_task_completed_reactionary_tasks` routes **GROUND_STRIKE and OCA_STRIKE** completions to `create_reaction_to_strike_task_completed` (eech reaction.c:182-192; body 609-697). Accepts `TASK_COMPLETED_SUCCESS` **or** `TASK_COMPLETED_PARTIAL` (eech reaction.c:629-633; failure → return, no follow-on). Only KEYSITE objectives react (switch has only that case, eech reaction.c:649-696). Branch on current keysite efficiency:
1. If `ground_strike_target` and `efficiency >= minimum_efficiency`: create another `create_ground_strike_task (task_side, objective, task, TRUE, task_database[GROUND_STRIKE].task_priority, NULL, NULL)` and **return** (no BDA) (eech reaction.c:659-674). No dedup check.
2. Else if `recon_target` and the keysite is not object of a live **RECON or BDA** task (attacker side) (eech reaction.c:676-681): create `create_bda_task (task_side, objective, task, TRUE, task_database[BDA].task_priority, NULL, NULL)` (eech reaction.c:683). The completed BDA then feeds back into the recon-completed reaction set (F4-F9) via the RECON/BDA case at eech reaction.c:170-171, closing the strike → BDA → (re-strike | insert) loop.

Note: **OCA_SWEEP completion has no follow-on** (listed in the no-op branch, eech reaction.c:194). Local `priority` (eech reaction.c:647) and `task_side` reads are partly dead: reaction priorities always come from task_database.

| constant | value | source |
|---|---|---|
| accepted results | SUCCESS or PARTIAL | eech reaction.c:629-633 |
| re-strike condition | ground_strike_target AND eff ≥ minimum_efficiency (0.3) | eech reaction.c:659-661 |
| BDA condition | recon_target AND no live RECON/BDA (attacker side) | eech reaction.c:676-681 |
| BDA priority | 9 | eech reaction.c:683, ts_dbase.c:416 |
| GROUND_STRIKE priority | 9 | eech reaction.c:663, ts_dbase.c:844 |

### REACT-F12 — Task-FAILED handling

There is **no reaction to failed tasks**. The FORCE-level dispatch calls the completed-reaction function for every terminal result (eech fc_msgs.c:1308), but:
- recon/BDA reactions require `TASK_COMPLETED_SUCCESS` exactly (eech reaction.c:358-361);
- strike reactions require SUCCESS or PARTIAL (eech reaction.c:629-633);
- so `TASK_COMPLETED_FAILURE` produces no follow-on tasks of any kind.

The only failure-specific behaviour is bookkeeping: `force_raw->task_generation[sub_type].failed++` vs `.completed++` (eech fc_msgs.c:1318-1325). A task that expires **unassigned** (`FLOAT_TYPE_EXPIRE_TIMER` reaching 0, eech ts_updt.c:105-120) terminates with `TASK_TERMINATED_EXPIRE_TIME_REACHED` and is marked `TASK_COMPLETED_FAILURE` without force notification through the assigned path (eech ts_msgs.c:295-306).

### REACT-F13 — Artillery-fire reaction: BAI or RECON against the firing battery

Behavior (eech reaction.c:703-810): called directly (not via entity message) from `create_artillery_strike_tasks` (periodic high-level generator, eech highlevl.c:2838) right after an artillery group is assigned a fire mission against a target (eech highlevl.c:3087-3091). The reacting side is the **target's** side (eech reaction.c:738). Dedup: return if the firing group is already object of a live **BAI or RECON** task of the victim's side (eech reaction.c:740-744).

Sector rating (influence maps, all sampled at the firing group's sector x/z, eech reaction.c:748-765):
```
rating = (1 - IMAP_AIR_DEFENCE) + IMAP_SURFACE_DEFENCE + 2 * IMAP_BASE_DISTANCE   (eech reaction.c:767-776)
max_rating = 4.0                                                                   (eech reaction.c:778)
priority = (rating / max_rating) * task_database[BAI].task_priority                (eech reaction.c:786, 801)
```
Branch on fog of war at the firing group's sector (eech reaction.c:780):
- FOW value `> 0.5 *` session FOW maximum (position known well) → **BAI**: `create_bai_task (side, group, NULL, FALSE /*not critical*/, priority, NULL, NULL)` (eech reaction.c:788);
- else → **RECON**: `create_recon_task (side, group, NULL, TRUE /*critical*/, priority, NULL, NULL)` (eech reaction.c:803). Note the recon branch **also** uses `task_database[BAI].task_priority` (4) in its priority formula, not RECON's 7 (eech reaction.c:801 — as written in source).

| constant | value | source |
|---|---|---|
| rating weights | AA-gap 1.0, SS-threat 1.0, base-distance 2.0; max 4.0 | eech reaction.c:770-778 |
| FOW branch threshold | 0.5 * FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE | eech reaction.c:780 |
| BAI critical flag | FALSE (only non-critical reaction task in the file) | eech reaction.c:788 |
| RECON critical flag | TRUE | eech reaction.c:803 |
| priority base (both branches) | task_database[BAI].task_priority = 4 | eech reaction.c:786, 801, ts_dbase.c:294 |
| dedup | firing group not object of live BAI/RECON (victim side) | eech reaction.c:740-741 |
| caller FOW gate | target sector FOW > 0.25 * max before artillery even fires | eech highlevl.c:3062 |

### REACT-F14 — Campaign Commander map-click reactions (Jabberwock mod, player-driven)

Behavior (eech reaction.c:816-993, marked "Jabberwock 031007 - Campaign Commander functions"): reached via multiplayer message `MESSAGE_LOCAL_BASE_CAMCOM_MESSAGE` → `create_reaction_to_map_click (en)` (eech msg_in.c:1160-1162). Acting side is the **player's** side (eech reaction.c:833). Enabled by `session_camcom` (default 0, eech cmndline.c:274); when `session_camcom == 2` every dedup check is bypassed (`... || session_camcom == 2`, eech reaction.c:859, 889, 899, 905, 935, 956, 980). Reproduces the recon-completed branch set against a clicked entity, without requiring any recon task:
- KEYSITE alive: TI + backup defender TI (same gates/threshold as F5/F6 but originator NULL, eech reaction.c:850-882); ground strike if `ground_strike_target` and eff ≥ min_eff, **with** a dedup check absent from F8 (eech reaction.c:885-894); **else** OCA strike/sweep if `oca_target` (note: OCA only when NOT ground_strike_target — different structure from F7, eech reaction.c:895-911); anti-ship strike if `ship_strike_target` (eech reaction.c:913-917). No SEAD-ring gate, no efficiency logging, no text messages.
- GROUP: AA group → SEAD (eech reaction.c:926-942); PRIMARY/SECONDARY_FRONTLINE, SELF_PROPELLED_ARTILLERY, SELF_PROPELLED_MLRS → BAI (explicit list instead of `frontline_flag`, eech reaction.c:944-963); any helicopter/aircraft group from an explicit 14-type list → CLOSE_AIR_SUPPORT at priority 6 (eech reaction.c:965-985, ts_dbase.c:476).

This is a player-command feature layered on the reaction module, not autonomous campaign behaviour; include only if the port implements Campaign Commander.

## 4. Interactions

- **Consumes:** task lifecycle events from the assignment engine (eech assign.c:592) and the task entity state machine (eech ts_msgs.c:345); keysite flags/efficiency (`keysite_database`, `FLOAT_TYPE_EFFICIENCY`); group database (`frontline_flag`, `default_entity_type`); per-side sector fog-of-war (highlevl FOW system); influence maps IMAP_AIR_DEFENCE / IMAP_SURFACE_DEFENCE / IMAP_BASE_DISTANCE (eech imaps.c, reaction.c:761-765); `task_database` priorities; `session_camcom` command-line/MP setting.
- **Drives:** the task generator constructors in taskgen.c (`create_cap_task`, `create_barcap_task`, `create_sead_task`, `create_troop_insertion_task`, `create_oca_strike_task`, `create_oca_sweep_task`, `create_ground_strike_task`, `create_anti_ship_strike_task`, `create_bda_task`, `create_bai_task`, `create_recon_task`, `create_close_air_support_task`), which put unassigned tasks on keysite lists for the assignment engine; force text messages (`MESSAGE_TEXT_SYSTEM_RECON_DATA`, eech reaction.c:400, 517, 565, 596); force task statistics (eech fc_msgs.c:1318-1325).
- **Feedback loops:** assigning the reaction-created GROUND_STRIKE/OCA_STRIKE/OCA_SWEEP tasks re-enters F2/F3 (defender CAP/BARCAP); completed BDA re-enters the recon-completed set (F4-F9); a created ground strike that completes re-enters F11 — this chain is the emergent "campaign pressure" cycle on a keysite.
- **Escort side-effect:** every reaction task, once assigned, may itself spawn an ESCORT task via the threat assessment in the assignment path (eech assign.c:598-619) — downstream of, but triggered by, reaction tasks.

## 5. Port mapping

(Per the provided port summary only; not verified against Lua.)

| Feature | Status | Note |
|---|---|---|
| REACT-F1 trigger path | PARTIAL | Port hooks completion on RTB rather than the EECH terminated/assessed pipeline; assigned-event hook implied by CAP/BARCAP reactions. |
| REACT-F2 CAP reaction | PORTED (reaction module) | CAP at real target base with 1800 s expiry per reaction.c:248. Port spawns a fresh group instead of assigning an existing idle one. |
| REACT-F3 BARCAP reaction | PORTED (reaction module) | BARCAP at real target base with 1800 s per reaction.c:298; whether the 6 km toward-attacker offset is reproduced is unstated — UNKNOWN detail. |
| REACT-F4 SEAD ring gate | PORTED (reaction module) | 4 km MAX_KEYSITE_SEAD_RANGE suppression gate implemented; count-limit (3) and abort-if->1 behaviour unstated — UNKNOWN detail. |
| REACT-F5 TI at weak keysite | PORTED (reaction module) | Efficiency-branched follow-ons implemented. |
| REACT-F6 backup defender TI | PORTED (reaction module) | Per reaction.c:429. |
| REACT-F7 OCA strike/sweep | PORTED (reaction module) | Efficiency-branched follow-on set includes OCA strike vs sweep. |
| REACT-F8 ground strike follow-on | PORTED (reaction module) | Part of efficiency-branched follow-ons. |
| REACT-F9 anti-ship strike | UNKNOWN | Not mentioned in port summary. |
| REACT-F10 group-objective SEAD/BAI | UNKNOWN | Not mentioned in port summary. |
| REACT-F11 strike→BDA→re-strike | PORTED (reaction module) | BDA creation + efficiency-branched follow-ons; completion-on-RTB proxy for EECH completeness assessment. |
| REACT-F12 task-failed handling | UNKNOWN | Explicitly unknown per port summary. |
| REACT-F13 artillery-fire reaction | UNKNOWN | Not mentioned in port summary (imap-rating priority formula likely absent). |
| REACT-F14 Campaign Commander map click | UNKNOWN | Player-command mod feature; not mentioned in port summary. |

Structural deviation to note for all PORTED rows: EECH reaction tasks are *unassigned task entities* later matched to existing idle groups (with 10-min unassigned expiry, dedup via live-task lists, and possible escort spawning); the port spawns fresh groups per reaction — dedup semantics (`entity_is_object_of_task` counting non-completed tasks) and the unassigned-expiry failure path have no direct equivalent.

## 6. Open questions

1. **Reaction flight sizes** — reaction.c never sets group/flight size; sizes fall out of the assignment engine (`get_suitable_registered_group`, member selection in assign.c) and task database fields not read here. Which aircraft counts EECH actually fields per reaction task type needs the assignment/suitable spec.
2. **BARCAP guide assumption** — F3 dereferences the task's first guide to find the attacker group (eech reaction.c:274-280, ASSERTs). Since TASK_ASSIGNED fires immediately after `push_task_onto_group_task_stack` (eech assign.c:943), a guide always exists; but if a port fires the assigned event earlier, the offset direction is undefined.
3. **Recon-branch priority using BAI's value** — eech reaction.c:801 scales the artillery-reaction RECON priority by `task_database[ENTITY_SUB_TYPE_TASK_BAI].task_priority`. Copy-paste bug or intentional (recon-of-artillery treated as pre-BAI)? Spec records it as written.
4. **Dead locals** — `task_side` (eech reaction.c:109), `priority` (eech reaction.c:367) and `priority` (eech reaction.c:647) are computed but unused; confirms reaction priorities are always database constants except F13.
5. **No dedup on ground strike (F8) and anti-ship strike (F9)** in the recon-completed path, while the map-click path *does* dedup ground strikes (eech reaction.c:889). Intentional (repeated strikes desired) or oversight? Port should decide and document.
6. **Efficiency threshold asymmetry** — F5 uses strict `<` and F8/F11 use `>=` against the same `minimum_efficiency`, so exactly-at-threshold keysites get struck, not captured. Worth preserving exactly.
7. **WUT data overrides** — all keysite flags and `minimum_efficiency` are overridable per-theatre via the WUT config reader (eech wutcfg.c:495-535, gwutcfg.c similar); the ks_dbase.c values in §2.3 are stock defaults only. Which WUT files ship with each theatre (and whether they change these bits) is outside this file's scope.
8. **`create_reaction_to_map_click` OCA gating differs from F7** (OCA only when not a ground-strike target, eech reaction.c:895-897) — mod author divergence from the original recon path; if Campaign Commander is ever ported, pick one behaviour deliberately.
9. **FOW value semantics** — thresholds compare `get_sector_fog_of_war_value` against fractions of a 4-hour default maximum (eech highlevl.h:69); the exact accumulation/decay model (FOG_OF_WAR_DECAY_RATE 30.0, eech highlevl.h:67) belongs to the FOW/imaps spec and is only referenced here.
