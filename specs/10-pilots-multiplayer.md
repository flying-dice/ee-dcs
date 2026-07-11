# EECH Spec 10 — Pilots, Players & Multiplayer Campaign Model

Sources:
- `aphavoc/source/entity/special/pilot/` — `pilot.h`, `pilot.c`, `pi_creat.c`, `pi_dstry.c`, `pi_int.c`, `pi_list.c`, `pi_msgs.c`, `pi_name.c`, `pi_pack.c`, `pi_str.c`, `pi_funcs.c`
- `aphavoc/source/entity/system/en_types/en_plyr.h`, `en_crew.h`
- `aphavoc/source/ui_menu/player/player.h`, `player.c`, `play_md.c`, `play_sc.c`
- `aphavoc/source/comms/comm_man.c`, `commsserver.c`
- Kill-credit call sites: `aphavoc/source/entity/mobile/mobile.c`, `entity/mobile/aircraft/helicop/helicop.c`, `hc_msgs.c`, `hc_dstry.c`, `entity/fixed/site/st_msgs.c`, `entity/fixed/scenic/sn_msgs.c`, `entity/fixed/siteupdt/su_msgs.c`, `entity/system/en_comms/en_comms.c`, `entity/special/group/gp_msgs.c`
- Player-task plumbing: `ui_menu/ingame/common/common.c`, `ui_menu/ingame/campaign/ca_selct.c`, `ai/taskgen/assign.c`

All citations are `eech <file>:<line>` relative to `E:\eech_source_code\aphavoc\source\` unless another root is shown.

## 1. Overview

EECH separates three "who is flying" concepts:

1. **PILOT entity** — a first-class campaign entity (`ENTITY_TYPE_PILOT`), one per human player in the session (server and every client), child of a FORCE via `LIST_TYPE_PILOT`. It carries name, side, rank, session kills, crew role, unique DirectPlay id and per-player difficulty. It is replicated client↔server like any other entity and is the anchor for mission locks (`LIST_TYPE_PILOT_LOCK`), the player's current task (`LIST_TYPE_PLAYER_TASK`), and the aircrew seat (`LIST_TYPE_AIRCREW`).
2. **Player log** — a *local, persistent* pilot career record (`player_log_type`) stored per machine in `playersv.bin` (up to 32 profiles). Holds per-side experience points, rank, medals, kill/death/weapon statistics, flying hours, mission counts. Promotions and medals are computed *locally on the machine owning the log* at mission termination.
3. **Connection model** — the server keeps a `connection_list_type` per client (DirectPlay id → pilot entity + gunship entity + resend/validation state). The server is fully authoritative: clients create their pilot and claim gunships by request packets; the whole campaign entity state is packed to a joining client, then kept in sync by the entity-comms message stream (`PACKET_TYPE_AI_DATA`).

Kill *credit* (group kills, task kills, task score points) is computed **server-side** in `credit_client_server_mobile_kill`; the personal career statistics for a remote player are forwarded to that player via `ENTITY_COMMS_PLAYER_KILL` and applied to their local player log.

## 2. Data model

### 2.1 PILOT entity (`pilot.h`)

`struct PILOT` — eech `entity/special/pilot/pilot.h:67-97`:

| Field | Type | Notes |
|---|---|---|
| `sub_type` | `entity_sub_types` | default `ENTITY_SUB_TYPE_PILOT_PILOT` (eech `entity/special/pilot/pi_creat.c:132`) |
| `pilots_name` | `char[STRING_TYPE_PLAYERS_NAME_MAX_LENGTH+1]` | max length 256 (eech `entity/system/en_funcs/en_str.h:113`); default `"UNKNOWN"` (eech `pi_creat.c:130`) |
| `rank` | int | `pilot_rank_types`, copied from player log at creation |
| `kills` | int | session (in-game) kill counter, drives high-score table |
| `unique_id` | int | DirectPlay player id (`direct_play_get_player_id ()`) |
| `crew_role` | `crew_roles` | default `CREW_ROLE_PILOT` (eech `pi_creat.c:134`) |
| `pilot_lock_root` | `list_root` | tasks/groups this pilot has locked in the planner UI |
| `aircrew_link` | `list_link` | seat in a helicopter (`LIST_TYPE_AIRCREW`) |
| `pilot_link` | `list_link` | membership of a FORCE (`LIST_TYPE_PILOT`) — **mandatory** parent, asserted at create (eech `pi_creat.c:152`) |
| `player_task_link` | `list_link` | current player mission (`LIST_TYPE_PLAYER_TASK`) |
| `side` | bitfield `NUM_SIDE_BITS` | |
| `difficulty_level` | bitfield `NUM_DIFFICULTY_LEVEL_BITS` | default `GAME_DIFFICULTY_INVALID` (eech `pi_creat.c:136`) |

`struct CLIENT_PILOT_REQUEST_DATA` (payload of `PACKET_TYPE_CLIENT_PILOT_REQUEST`) — name, string_length, side, rank, sub_type, unique_id, difficulty — eech `pilot.h:105-118`.

Overloaded entity accessors (`pi_int.c:306-349`): `INT_TYPE_CREW_ROLE`, `INT_TYPE_DIFFICULTY_LEVEL`, `INT_TYPE_ENTITY_SUB_TYPE`, `INT_TYPE_KILLS`, `INT_TYPE_PILOT_RANK`, `INT_TYPE_SIDE`, `INT_TYPE_UNIQUE_ID`. Setting `INT_TYPE_KILLS` locally has the side effect of rebuilding the high-score table (eech `pi_int.c:119-131`).

Pack/unpack (`pi_pack.c:79-180`): in `PACK_MODE_CLIENT_SESSION` (full join) the pilot packs sub_type, name, rank, kills, unique_id, pilot_lock root, aircrew link, pilot link, player_task link, side, difficulty; in `PACK_MODE_BROWSE_SESSION` (session browse) only sub_type, name, rank, kills, unique_id, pilot link, side (eech `pi_pack.c:108-171`). `crew_role` is deliberately not packed; unpack forces `CREW_ROLE_PILOT` (eech `pi_pack.c:238`).

Message responses (`pi_msgs.c:157-170`): only `ENTITY_MESSAGE_LINK_PARENT` is live — linking into `LIST_TYPE_AIRCREW` notifies the campaign group screen (`CAMPAIGN_SCREEN_GROUP_ADD_MEMBER`), linking into `LIST_TYPE_PILOT` refreshes the chat page pilot list (eech `pi_msgs.c:109-136`). The link/unlink-child and unlink-parent handlers exist only under `#if DEBUG_MODULE` (dead).

### 2.2 Player/crew enums (`en_plyr.h`, `en_crew.h`)

- `entity_players`: `ENTITY_PLAYER_AI`, `ENTITY_PLAYER_LOCAL`, `ENTITY_PLAYER_REMOTE` — eech `entity/system/en_types/en_plyr.h:67-73`. Every mobile entity carries `INT_TYPE_PLAYER`; AI is the default, LOCAL means "flown by this machine", REMOTE means "flown by another machine in the session".
- `crew_roles`: `CREW_ROLE_PILOT`, `CREW_ROLE_CO_PILOT` — eech `entity/system/en_types/en_crew.h:67-72`. Toggled by the cockpit seat-switch (`gunships/views/vm_vckpt.c:2992` sets CO_PILOT, `:3031` sets PILOT); reset to PILOT whenever a gunship is assigned (eech `entity/mobile/aircraft/helicop/helicop.c:394`). Consumed only by avionics/MFD code (e.g. `gunships/avionics/apache/ap_mfd.c:732`), not by campaign logic.

### 2.3 Player log (career) structures (`ui_menu/player/player.h`)

- `PILOT_RANK_TYPES`: `NONE, LIEUTENANT, CAPTAIN, MAJOR, LT_COLONEL, COLONEL` — eech `ui_menu/player/player.h:91-101`. Display names set in `initialise_medal_and_promotion_names` (eech `ui_menu/player/player.c:172-177`).
- `MEDAL_TYPES` (13): `NONE, SAUDI, LEBANON, TAIWAN, ARMY_AVIATOR, SENIOR_AVIATOR, MASTER_AVIATOR, PURPLE_HEART, AIR_MEDAL, FLYING_CROSS, SILVER_STAR, DISTINGUISHED_SERVICE, MEDAL_OF_HONOUR` — eech `player.h:126-143`. Separate US/CIS display-name tables (eech `player.c:144-170`).
- `WEAPON_LOG_FIELDS`: `FIRED`, `HIT` — eech `player.h:112-118`.
- `player_kills_type`: air, ground, sea, fixed, deaths, friendly, fixed_wing, helicopter, air_defence, armour, artillery — eech `player.h:154-169` (v1 legacy variant `player.h:173-182`).
- `player_commissioned_type`: day:5 / month:4 / year:7 bitfields — eech `player.h:188-194`.
- `player_warzone_log`: linked list of {warzone_name, missions, flying_seconds} — eech `player.h:202-208`.
- `player_side_log_type` (per side!): rank, experience, failed_tours, missions_flown, successful_tours, air_medal_counter, `medals[NUM_MEDAL_TYPES]`, `level[NUM_PLAYER_LEVELS]` (NUM_PLAYER_LEVELS = 10, eech `player.h:75`), flying_seconds, mission_success_rate, kills, `weapon_usage[NUM_ENTITY_SUB_TYPE_WEAPONS][2]`, per-gunship flying seconds/missions, helicopters_lost, warzone_log — eech `player.h:216-249`.
- `player_log_type`: name, unique_id, date_commissioned, `side_log[NUM_ENTITY_SIDES+1]`, next — eech `player.h:280-297`. A linked list of profiles; `current_player_log` is the active one (eech `player.c:83-86`).
- `player_medal_criteria`: points_req, pilot_rank, wings_medal, num_campaign_medals, medal_required, medal_multiplier — eech `ui_menu/player/play_md.c:114-123`.
- High-score entry `pilot_score_type`: kills, valid, side, name — eech `entity/special/pilot/pilot.c:97-108`; table of `NUM_TABLE_ENTRIES` (10, eech `pilot.c:77`).

### 2.4 Server connection record

`connection_list_type` (used throughout `commsserver.c` / `comm_man.c`; fields observed at eech `comms/commsserver.c:116-161`): connection_id (DPID), receive buffer + size, `already_sent_query_data`, group/personal resend timers, group/personal frame ids, `validation_count`, `connection_validation_time`, **`pilot_entity`** (set on pilot request, eech `comms/comm_man.c:1933`), **`gunship_entity` / `gunship_number`** (set on gunship request, eech `comm_man.c:2019-2021`), `next`.

### 2.5 Data-driven flags

- `task_database[type].counts_towards_player_log` — per task type; read by the warzone/GWUT parser (eech `gwutcfg.c:1602`), defaults in eech `entity/special/task/ts_dbase.c` (e.g. FALSE at `:138`, TRUE at `:257`). Gates whether completing that task type writes to the player career log (eech `entity/special/group/gp_msgs.c:1248`).
- `vehicle_database[sub_type].map_icon` — used to classify ground kills into armour/artillery stats (eech `ui_menu/player/player.c:945-952`).
- `keysite_database[type].assign_task_count` / `.reserve_task_count` — data-driven counts used when reserving tasks for players (eech `ai/taskgen/assign.c:218-220`, reader `gwutcfg.c`).

## 3. Features

### PILOT-F1 — Pilot entity lifecycle (create)

Behavior: `create_local` allocates the raw PILOT, zeroes it, sets defaults (name "UNKNOWN", sub_type PILOT_PILOT, crew role PILOT, difficulty INVALID), applies given attributes, asserts a FORCE parent exists for `pilot_link`, then links into `LIST_TYPE_AIRCREW` (only if a parent was supplied) and `LIST_TYPE_PILOT` (eech `pi_creat.c:79-187`). Server-mode create creates locally then transmits a remote create to all clients; client-mode create transmits in TX flow or applies locally in RX flow (eech `pi_creat.c:193-254`; function-table overload `pi_creat.c:260-267`).

Constants:

| Name | Value | Source |
|---|---|---|
| default name | "UNKNOWN" | eech `pi_creat.c:130` |
| default sub_type | `ENTITY_SUB_TYPE_PILOT_PILOT` | eech `pi_creat.c:132` |
| default crew_role | `CREW_ROLE_PILOT` | eech `pi_creat.c:134` |
| default difficulty | `GAME_DIFFICULTY_INVALID` | eech `pi_creat.c:136` |

Trigger: server pilot at campaign start (`create_server_pilot`), client pilot on join acceptance, remote replicas on every other machine.

### PILOT-F2 — Pilot entity destroy / cleanup

Behavior: on local destroy, the server first broadcasts a "quit" text message (`send_pilot_quit_message`, F5); then the pilot: unlinks all its `LIST_TYPE_PILOT_LOCK` children (releasing mission/group locks), removes itself from `LIST_TYPE_AIRCREW` (vacating the seat), `LIST_TYPE_PILOT` (force roster) and `LIST_TYPE_PLAYER_TASK` (dropping the assigned mission link); updates the campaign chat page; if the destroyed pilot is the local player's, the global `pilot_entity` pointer is nulled raw (to avoid recursive destroy) (eech `pi_dstry.c:79-163`). Destroy is overloaded for destroy/destroy-family/kill uniformly (eech `pi_dstry.c:231-244`).

`set_pilot_entity (NULL)` (local quit path) forces comms into TX flow before destroying so the server also destroys the client's pilot (eech `pilot.c:160-179`).

Trigger: player quits session, server kicks/timeouts a client, session teardown.

### PILOT-F3 — Local player pilot creation from the player log (server)

Behavior: `create_server_pilot` (server only) builds the pilot entity from the *current player log*: name = profile name, side = global gunship side, rank = `get_player_log_rank (side, log)`, sub_type PILOT_PILOT, unique_id = DirectPlay player id, difficulty = global difficulty; parents it under the side's FORCE; announces the join; sets it as the local `pilot_entity` (eech `pilot.c:271-326`). `set_pilot_entity` on a server also publishes the pilot name as the network hostname used in heartbeat packets (eech `pilot.c:153-157`); on a client it re-enables the gunship-screen NEXT button (UI) (eech `pilot.c:144-151`).

Formulas: none. Trigger: campaign/session start on the host.

### PILOT-F4 — Client join: pilot request / accept (MP)

Behavior:
1. Client packs `client_pilot_request_data` from its local player log (name, chosen side, per-side rank, sub_type PILOT_PILOT, DirectPlay id, local difficulty setting) and sends `PACKET_TYPE_CLIENT_PILOT_REQUEST` to the server (eech `pilot.c:332-362`).
2. Server (assert COMMS_MODEL_SERVER) unpacks it, calls `create_new_pilot_entity` (creating the pilot client/server so *all* machines get a replica), records `connection->pilot_entity`, and answers with entity-comms `ENTITY_COMMS_PILOT_REQUEST_ACCEPTED (received_id, entity_index)` (eech `comm_man.c:1886-1936`).
3. On the requesting client, the handler matches `destination_id == direct_play_get_player_id ()` and calls `set_pilot_entity` on the unpacked index (eech `entity/system/en_comms/en_comms.c:4356-4389`). A personal-packet variant `PACKET_TYPE_PILOT_REQUEST_ACCEPTED` does the same (eech `comm_man.c:2253-2272`).

Side selection is client-side before the request: the gunship-select UI sets the global gunship side (eech `ui_menu/gunships/guns_sc.c:656`; free-flight derives side from the gunship type table, eech `gameflow/gameflow.c:196`); the chosen side rides in `pilot_data.side` and determines which FORCE the pilot entity is parented to. Rank rides in from the client's own log — the server trusts it.

Trigger: once per client joining a session.

### PILOT-F5 — Join/quit announcements, session pilot count, auto-pause

Behavior: `get_session_pilot_count` walks SESSION → FORCEs → `LIST_TYPE_PILOT` children and counts pilots (eech `pilot.c:368-398`). On join, a system chat message "<name> joined - N player(s) connected" is sent to all (`MESSAGE_TEXT_SYSTEM_NEW_PILOT`) and written to the server log (eech `pilot.c:186-219`). On quit, same with count−1 (eech `pilot.c:225-257`); additionally, if the `pause_server` command line option is set and ≤1 player remains, the server forces pause (`force_pause_acceleration`) (eech `pilot.c:259-263`). Any new connection registration also cancels pause/time acceleration (`set_min_time_acceleration`, eech `commsserver.c:96`).

Constants:

| Name | Value | Source |
|---|---|---|
| auto-pause threshold | remaining players ≤ 1 (with `command_line_pause_server`) | eech `pilot.c:259` |

### PILOT-F6 — Session (in-game) kill counter & high-score table

Behavior: each pilot entity has `kills` (`INT_TYPE_KILLS`), replicated client/server. Any local set of `INT_TYPE_KILLS` rebuilds the high-score table (eech `pi_int.c:119-131`). `update_pilot_high_score_table` gathers every pilot in the session (all forces), copies {kills, side, name}, quicksorts descending by kills, and keeps the top 10 (`NUM_TABLE_ENTRIES` = 10, eech `pilot.c:77`; sort eech `pilot.c:540-572`; build eech `pilot.c:431-534`). Accessors: `get_high_score_table_entry` (eech `pilot.c:698-723`), `get_high_score_table_first_name` (eech `pilot.c:729-744`), UI list renderer with blue/orange side colouring (eech `pilot.c:650-692`).

Dead code (`#if 0`): full-screen `draw_high_score_table` (eech `pilot.c:578-644`, uses `FLASH_RATE` 1.0 at `pilot.c:79`) and `draw_special_restart_text` (eech `pilot.c:750-793`).

Note: the only live writer of a pilot entity's `INT_TYPE_KILLS` found is dead/commented code (see PILOT-F16); the counter and table exist and replicate, but the in-session pilot-vs-pilot scoring that fed it is commented out in the source used here.

### PILOT-F7 — Player career log & persistence

Behavior: up to `MAXIMUM_NUMBER_OF_PLAYERS` = 32 local profiles (eech `ui_menu/player/play_sc.c:82`), names truncated to `MAXIMUM_PLAYER_NAME` = 16 chars (eech `play_sc.c:84`, enforced `play_sc.c:1995-1999`). New profiles get a fresh unique id, today's date as commission date, and **for each side** starting rank = `command_line_player_start_rank` bounded to [LIEUTENANT, COLONEL] with matching starting experience `get_player_points_from_rank (start_rank)` (eech `play_sc.c:1919-1975`); the command-line default is `PILOT_RANK_LIEUTENANT` (eech `cmndline.c:153`, ini hook `eechini.c:1060`). Persistence: binary files `playersv.bin` (current, versioned), falling back to legacy `players2.bin` (v1) then `players.bin` (v0) on load (eech `play_sc.c:1446-1620`); saved with `PLAYERS_VERSION_CURRENT` (enum eech `play_sc.c:86-94`; save eech `play_sc.c:1696-1760`). The log is backed up before flight and restored on abort so an abandoned mission does not mutate the career (`backup_current_player_log` / `restore_log_from_backup`, eech `player.c:1150-1181`; backup taken when a gunship is assigned, eech `helicop.c:437`).

The `level[10]` array's first 5 blue-side slots are exposed as debug file-tag variables TRAINING1..5_LEVEL (eech `player.c:368-379`).

### PILOT-F8 — Rank & promotion thresholds

Behavior: rank is a pure function of accumulated per-side experience points. `award_player_rank` recomputes rank from points after a successful mission and returns the new rank if it changed (else `PILOT_RANK_NONE`) (eech `play_md.c:1365-1389`). There is **no demotion guard** — rank is set to whatever the points imply (points can only be reduced via `set_player_log_experience` clamping at 0, eech `player.c:540-546`).

Promotion table (`get_player_rank_from_points`, eech `player.c:408-431`; base constants eech `player.c:73-77`):

| Rank | Points required (≥) | Source |
|---|---|---|
| Lieutenant | 0 (`LIEUTENANT_POINTS_BASE`) | eech `player.c:73` |
| Captain | 7 500 (`CAPTAIN_POINTS_BASE`) | eech `player.c:74` |
| Major | 32 000 (`MAJOR_POINTS_BASE`) | eech `player.c:75` |
| Lt. Colonel | 120 000 (`LT_COLONEL_POINTS_BASE`) | eech `player.c:76` |
| Colonel | 250 000 (`COLONEL_POINTS_BASE`) | eech `player.c:77` |

`get_player_points_from_rank` is the inverse (returns the base, eech `player.c:437-489`).

Rank → "task level" mapping exists (Lieutenant 6, Captain 7, Major 8, Lt.Col 9, Colonel 10; eech `player.c:1013-1066`) but `get_player_log_task_level` has **no callers** outside `player.c` — dead API (rank does not gate mission availability in this source).

Trigger: `award_player_rank` runs only on `TASK_COMPLETED_SUCCESS` with points > 0 (see F9).

### PILOT-F9 — Mission termination: experience, stats, medal/promotion awarding

Behavior: `notify_gunship_entity_mission_terminated` (eech `helicop.c:693-853`) is the single career-update choke point. Inputs: the completed task's `INT_TYPE_TASK_SCORE` (accumulated kill points, see F16) and `INT_TYPE_TASK_COMPLETED` outcome. Sequence:

1. `points = INT_TYPE_TASK_SCORE`; `inc_player_log_experience (side, log, points)` (eech `helicop.c:721-725`).
2. `inc_player_log_missions_flown` (also bumps the per-gunship-type mission counter) (eech `helicop.c:729`, impl `player.c:610-624`).
3. Outcome switch (eech `helicop.c:731-836`):
   - `TASK_COMPLETED_SUCCESS`: if points > 0 → valour medal (F10) and promotion check (F8); always → air-medal tick (success=TRUE, F11), aviator wings (F12), purple heart (F13); success-rate sample = **1.0**.
   - `TASK_COMPLETED_PARTIAL`: aviator wings, purple heart; success-rate sample = **0.5** (air-medal counter neither incremented nor reset).
   - `TASK_COMPLETED_FAILURE`: aviator wings; air-medal counter reset (success=FALSE); success-rate sample = **0.0**.
4. Awarded medals are OR'd as bits (`medal |= 1 << awarded_medal`) and stored on the task via `INT_TYPE_AWARDED_MEDALS`, promotion via `INT_TYPE_AWARDED_PROMOTION`, for the debrief screen (eech `helicop.c:842-844`).
5. Debrief page auto-selected; `mission_logged = TRUE` (eech `helicop.c:850-852`).

Success rate is a running mean over missions flown: `rate = (missions*old_rate + sample) / missions` (mission count already incremented) (eech `player.c:983-1007`).

MP/trigger plumbing: when a group's task terminates and `task_database[type].counts_towards_player_log` is TRUE, the server calls this function directly for `ENTITY_PLAYER_LOCAL` members and sends `ENTITY_COMMS_PLAYER_TASK_TERMINATED` to remote members (eech `gp_msgs.c:1248-1260`); the receiving client runs the same function against its own local player log (eech `en_comms.c:4560-4591`). It is also invoked when the player releases a completed task's gunship (eech `helicop.c:309-315`) and when the player's gunship is destroyed while its task is already `TASK_STATE_COMPLETED` (eech `hc_dstry.c:363-375`). If the gunship dies with no completed task and the mission wasn't yet logged, the log records a flown mission with success sample 0.0 (eech `hc_dstry.c:376-385`). Mission-complete UI/music (no career effect) goes through `notify_gunship_entity_mission_completed` (eech `helicop.c:653-687`) and its comms twin `ENTITY_COMMS_PLAYER_TASK_COMPLETED` (eech `en_comms.c:4527-4558`).

Constants:

| Name | Value | Source |
|---|---|---|
| success-rate sample (success/partial/failure) | 1.0 / 0.5 / 0.0 | eech `helicop.c:781,805,826` |

### PILOT-F10 — Valour medals (per-mission points)

Behavior: `award_valour_medal (side, mission_points)` walks the criteria table from most to least prestigious (Medal of Honour → Distinguished Service → Silver Star → Flying Cross, `NUMBER_OF_VALOUR_MEDALS` = 4, eech `play_md.c:87`) and awards the *first* medal whose criteria pass; the medal's count is incremented (repeatable) (eech `play_md.c:1179-1237`). `query_award_medal` checks: (a) player rank ≥ criteria rank; (b) required aviator-wings medal owned (if any); (c) count of campaign medals (SAUDI+LEBANON+TAIWAN) ≥ required; (d) prerequisite-medal count ≥ `(already_owned_count_of_this_medal + 1) * medal_multiplier` (eech `play_md.c:1109-1173`).

Criteria table (eech `play_md.c:218-260`); note the points test is strictly `points > points_req` (eech `play_md.c:1212`):

| Medal | points > | min rank | wings needed | campaign medals | prerequisite medal | multiplier |
|---|---|---|---|---|---|---|
| Medal of Honour | 5000 | Major | Senior Aviator | 2 | Distinguished Service | 2 |
| Distinguished Service | 4000 | Captain | Army Aviator | 1 | Silver Star | 3 |
| Silver Star | 3200 | Lieutenant | — | 0 | Flying Cross | 2 |
| Flying Cross | 2600 | Lieutenant | — | 0 | — | 0 |

Trigger: successful mission with points > 0 (F9 step 3).

### PILOT-F11 — Air Medal (consecutive successes)

Behavior: per-side `air_medal_counter` increments on success; at ≥ `NUM_NEEDED_TO_AWARD_AIR_MEDAL` = **3** (eech `play_md.c:89`) the Air Medal count increments and the counter resets to 0; on failure the counter resets without award (eech `play_md.c:1304-1359`). Partial completions leave the counter untouched (F9).

### PILOT-F12 — Aviator wings (flight-time medals)

Behavior: `award_aviator_wings` computes total career flying hours for the side as `flying_seconds / ONE_HOUR` (ONE_HOUR = 3600 s, eech `E:\eech_source_code\modules\maths\constant.h:166`) and awards the highest qualifying badge **once only** (returns MEDAL_TYPE_NONE if already owned) (eech `play_md.c:997-1056`).

| Badge | Hours ≥ | Source |
|---|---|---|
| Army Aviator | 4 (`MEDAL_HOURS_TO_BECOME_ARMY_AVIATOR`) | eech `player.h:85` |
| Senior Aviator | 15 (`MEDAL_HOURS_TO_BECOME_SENIOR_AVIATOR`) | eech `player.h:83` |
| Master Aviator | 50 (`MEDAL_HOURS_TO_BECOME_MASTER_AVIATOR`) | eech `player.h:81` |

Flying seconds accrue via `inc_player_log_flying_seconds` (also per-gunship-type, eech `player.c:773-785`). Trigger: every mission termination regardless of outcome (F9).

### PILOT-F13 — Purple Heart

Behavior: awarded (repeatably) when, at mission termination (success or partial only), the player's gunship is alive **and** has any of these dynamics damage flags: main/tail rotor, either engine, either engine fire, low hydraulics, low/high oil pressure, stabiliser (eech `play_md.c:1245-1296`). i.e. "brought a damaged helicopter home".

### PILOT-F14 — Campaign medals

Behavior: `award_campaign_medal (side, medal)` increments one of SAUDI/LEBANON/TAIWAN (only medals in range NONE < m ≤ TAIWAN accepted) (eech `play_md.c:1062-1103`). Awarded on campaign completion (call sites in campaign-end flow; a debug/test harness in `play_sc.c:2245-2303` cycles them). These feed the valour-medal campaign-medal criterion (F10).

### PILOT-F15 — Weapon usage, kills classification, deaths & losses (career stats)

Behavior:
- Kill classification `inc_player_log_kills (side, log, victim)` (eech `player.c:912-977`): if victim is the player's own gunship → deaths++; if victim side ≠ player side: FIXED_WING → fixed_wing+air; HELICOPTER → helicopter+air; ANTI_AIRCRAFT → air_defence+ground; ROUTED_VEHICLE → ground, plus armour if `map_icon` is TANK/APC or artillery if ARTILLERY (DATA-DRIVEN via `vehicle_database`, eech `player.c:945-952`); SHIP_VEHICLE → sea; BRIDGE/CITY_BUILDING/SCENIC/SITE/SITE_UPDATABLE → fixed. Same-side victim → friendly++.
- Deaths/losses on releasing the gunship (`set_gunship_entity`, non-free-flight): alive but landed off-base → helicopters_lost++; dead → deaths++ and helicopters_lost++ (eech `helicop.c:317-335`).
- Weapon fired/hit counters `inc_player_weapon_log_fired/hit` (eech `player.c:1098-1144`). Bug preserved for reference: `get_player_weapon_log_hit` returns the FIRED field, not HIT (eech `player.c:1111-1118`).

### PILOT-F16 — Kill credit pipeline (server) & MP forwarding

Behavior: `credit_client_server_mobile_kill (victim, aggressor)` — server only, victim still alive at call time (eech `mobile.c:365-484`):
1. **Group kills**: aggressor's group `INT_TYPE_KILLS`++ (eech `mobile.c:391-400`).
2. **Task kills & score**: aggressor's primary task `INT_TYPE_KILLS`++; `calculate_task_points_for_kill` added to task `INT_TYPE_TASK_SCORE`; kill recorded on the task (`add_kill_to_task`) and broadcast (`ENTITY_COMMS_TASK_KILL`) (eech `mobile.c:406-430`). This task score is exactly what F9 later pays out as player experience.
3. **Task losses**: victim's primary task records the loss (`add_loss_to_task`, `ENTITY_COMMS_TASK_LOSS`) (eech `mobile.c:436-443`).
4. **Player career kill** (non-free-flight): aggressor `ENTITY_PLAYER_LOCAL` → `inc_player_log_kills` on the server's own log; `ENTITY_PLAYER_REMOTE` → `ENTITY_COMMS_PLAYER_KILL (aggressor, victim)` sent to clients; the machine where either the victim or the aggressor is LOCAL applies `inc_player_log_kills` to its log (eech `mobile.c:449-459`; client handler eech `en_comms.c:4496-4525`).
5. System chat kill message + force statistics + `ENTITY_COMMS_MOBILE_KILL` (eech `mobile.c:465-477`).

Kill points formula (`calculate_task_points_for_kill`, eech `mobile.c:281-359`): base = victim `INT_TYPE_POINTS_VALUE` (per-entity data value); 0 if base is 0 or victim is same side; if the victim was targeting an aircraft/vehicle: **+10%** if that target is in the aggressor's own group, **+50%** if in another friendly group; result rounded up (ceil).

| Constant | Value | Source |
|---|---|---|
| own-group threat bonus | +10% | eech `mobile.c:338` |
| other friendly group threat bonus | +50% | eech `mobile.c:346` |
| same-side kill points | 0 | eech `mobile.c:306-311` |

Detection sites: helicopters credit on transition to critically-damaged (eech `hc_msgs.c:238-254`); fixed entities (site/scenic/site-updatable) credit the player log directly on destruction if `FLOAT_TYPE_FIXED_OBJECT_IMPORTANCE ≥ 0.5`, LOCAL → direct, REMOTE → `ENTITY_COMMS_PLAYER_KILL` (eech `st_msgs.c:125-143`, `sn_msgs.c:126`, `su_msgs.c:131`). Player shot down: LOCAL → `dynamics_kill_model (DYNAMICS_DESTROY_SHOT_DOWN)` (death logged later at landing assessment — comment at eech `hc_msgs.c:317-318`); REMOTE → `ENTITY_COMMS_PLAYER_KILL` + kill entity (eech `hc_msgs.c:307-332`).

Dead code: an in-session pilot-vs-pilot scoring block (increment/decrement pilot entity `INT_TYPE_KILLS`, with a cooperative-mode friendly-kill −1 rule via `get_global_session_special_gametype () == SPECIAL_GAME_TYPE_COOPERATIVE`) is fully commented out (eech `hc_msgs.c:255-297`).

### PILOT-F17 — Player-flyable filtering ("suitable for player")

Behavior: `get_local_entity_suitable_for_player (en, pilot)` (eech `helicop.c:1825-1966`) gates which campaign entities a player may fly. Live checks: entity non-NULL; **side must match the pilot's side** unless free flight (eech `helicop.c:1845-1851`); `INT_TYPE_PLAYER_CONTROLLABLE` flag set (eech `helicop.c:1857-1860`); **not already flown by another human** (`INT_TYPE_PLAYER != ENTITY_PLAYER_AI` → refuse, eech `helicop.c:1909-1912`); alive (eech `helicop.c:1918-1921`); not ejected (eech `helicop.c:1927-1930`). Checks disabled by community edits (noted as modified, not active): helicopter-only type check (eech `helicop.c:1835-1839`), Apache/Havoc install check (`helicop.c:1867-1871`), sub-type whitelist `default:` fatal (`helicop.c:1898-1902`), landing/taxiing state check (`helicop.c:1936-1949`), and "task already complete" refusal changed to allow (eech `helicop.c:1955-1965`). Wrappers: any group member suitable → group suitable (eech `entity/special/group/group.c:588-613`); keysite variant (eech `entity/special/keysite/keysite.c:1705`).

Trigger: gunship selection UI, external-view fly-here (eech `helicop.c:579-632`), and re-validated when setting the gunship (eech `helicop.c:232-240`).

### PILOT-F18 — Planner locks & AI task reservation for players

Behavior: while browsing missions/groups in the campaign planner, the selection is *locked* to the pilot entity client/server-wide: selecting a mission clears the pilot's previous TASK locks then sets `LIST_TYPE_PILOT_LOCK` parent of the task to the pilot; if another pilot already holds the lock the selection is refused (eech `ui_menu/ingame/campaign/ca_selct.c:274-343`); identical logic for groups (eech `ca_selct.c:349-416`). The AI task assigner **skips any task locked by a pilot** (eech `ai/taskgen/assign.c:235-238`) and additionally **reserves non-critical tasks for players**: up to `keysite_database[type].reserve_task_count` non-critical tasks (whose expiry timer still exceeds `KEYSITE_TASK_ASSIGN_TIMER`) are passed over per keysite per pass (eech `assign.c:244-255`; counts DATA-DRIVEN via keysite database, eech `assign.c:218-220`). AI group selection also refuses groups locked by a pilot (eech `assign.c:445`). Locks are released when the pilot entity is destroyed (F2) or when the task/group is destroyed (eech `entity/special/task/ts_dstry.c:132`, `entity/special/group/gp_dstry.c:137`).

### PILOT-F19 — Player task assignment & release

Behavior:
- Assignment: `player_assigned_new_task (mobile, task)` sets the gunship (F20) then links the pilot entity under the task via `LIST_TYPE_PLAYER_TASK` client/server (eech `ui_menu/ingame/common/common.c:647-672`). `get_player_task (pilot)` returns that parent (eech `pilot.c:413-425`).
- Release: `player_quit_current_task` (called when the gunship is cleared while one was set) only notifies the campaign screen and clears UI selections (eech `common.c:678-685`; call site eech `helicop.c:530-533`); the `LIST_TYPE_PLAYER_TASK` link itself persists until the task is destroyed (task destroy unlinks its player-task children, eech `ts_dstry.c:132`) or the pilot is destroyed (F2).
- Server-side control assumption: `helicopter_assume_player_control` (server) — if the helicopter was on an ENGAGE task, the guide is destroyed and the member reassigned to a valid task before the player takes over (eech `helicop.c:1972-2010+`).

### PILOT-F20 — Gunship possession & `INT_TYPE_PLAYER` transitions

Behavior: `set_gunship_entity (en)` (eech `helicop.c` ~`:180-551`) is the local possession switch, always forced into TX comms flow (eech `helicop.c:282-284`):
- Releasing the old gunship: persist fuel; run mission-termination if its primary task completed (eech `helicop.c:309-315`); log deaths/losses (F15); `INT_TYPE_PLAYER` back to `ENTITY_PLAYER_AI` client/server (eech `helicop.c:360`); landed-with-task helicopters bumped back to NAVIGATING (eech `helicop.c:363-374`); old group set weapons-free / position-hold cleared (eech `helicop.c:401-419`).
- Taking the new gunship: pilot entity seated via `LIST_TYPE_AIRCREW` parent = gunship and crew role reset to PILOT (eech `helicop.c:391-395`); `INT_TYPE_PLAYER` set to **`ENTITY_PLAYER_REMOTE`** client/server (so every machine, including the server for a client's gunship, marks it human; the owning machine's local semantics treat its own pilot's gunship as LOCAL) (eech `helicop.c:427`); invulnerability timer `command_line_user_invulnerable_time` applied (eech `helicop.c:246`); player log backed up (eech `helicop.c:437`); gunship `INT_TYPE_UNIQUE_ID` set to the DirectPlay player id (eech `helicop.c:500`); group set weapons-hold above simple avionics realism (eech `helicop.c:478-494`).

### PILOT-F21 — MP gunship claim (request/accept/refuse)

Behavior: client sends `PACKET_TYPE_CLIENT_GUNSHIP_REQUEST` with the chosen helicopter's entity index; server resolves the index — if the entity no longer exists it replies `PACKET_TYPE_GUNSHIP_REQUEST_REFUSED`, else it records `connection->gunship_number/gunship_entity` and replies `PACKET_TYPE_GUNSHIP_REQUEST_ACCEPTED` with the index (eech `comm_man.c:1938-2025`). Client on refusal sets server response REFUSE (UI retries) (eech `comm_man.c:2187-2199`); on acceptance resolves the entity and calls `assign_entity_to_user` (wrapping the F20 possession switch inside planner-event stack juggling) (eech `comm_man.c:2201-2251`). Note the server does *not* re-check `suitable_for_player` here — existence only; suitability was checked client-side (F17).

### PILOT-F22 — MP session join & campaign state sync (host authority)

Behavior (campaign level):
- **Session create (host)**: `server_create_session` creates the DirectPlay session/player and sets the server id (eech `commsserver.c:386-441`).
- **Browse/query**: on `PACKET_TYPE_SESSION_QUERY` the server sends, once per connection (`already_sent_query_data`), `PACKET_TYPE_SESSION_INFO` containing: hard version int (`VERSION_NUMBER_INT`, checked so client and server run identical builds/data, eech `comm_man.c:766-775`), map dimensions (`NUM_MAP_X_SECTORS`, `NUM_MAP_Z_SECTORS`, `SECTOR_SIDE_LENGTH`), warzone data path, population-placement / side-data / campaign-population filenames, connected-player count, and a `PACK_MODE_BROWSE_SESSION` pack of the session (which includes each pilot's name/rank/kills/side — see F6 data) (eech `comm_man.c:713-944`).
- **Server-side settings**: `PACKET_TYPE_SETTINGS_REQUEST`/`SETTINGS_DATA` push server-authoritative option values to clients (observed set: WUT selection, season, vector flight model, campaign map update interval, chaff/flare/smoke effectiveness, cloud puffs, camcom, planner goto button, russian NVG, ground-radar-ignores-infantry, comms packet data size) (eech `comm_man.c:948-1200`).
- **Full join**: `PACKET_TYPE_CLIENT_CAMPAIGN_DATA_REQUEST` → server flushes its group send buffer, packs the *entire session* in `PACK_MODE_CLIENT_SESSION` (growing the buffer as needed), appends the current group frame id, and sends `PACKET_TYPE_MISSION_DATA` (eech `comm_man.c:2027-2124`). Client, on receipt, loads terrain/routes, creates local-only entities, and unpacks the whole campaign (eech `comm_man.c:2274-2360`), then reports its frame id (`PACKET_TYPE_CLIENT_FRAME_ID`); the server replays every group packet between snapshot and now so the client catches up (eech `comm_man.c:2126-2185`).
- **Steady state**: all campaign mutations flow as entity-comms messages inside `PACKET_TYPE_AI_DATA` packets, processed identically on all machines (eech `comm_man.c:2403-2443`); everything above (pilot create, kills, task links, INT sets) rides this channel.

### PILOT-F23 — Disconnect, timeout, kick & endgame handling

Behavior:
- **Clean quit**: client sends `PACKET_TYPE_END_GAME`; server sets that connection's gunship `INT_TYPE_PLAYER` back to `ENTITY_PLAYER_AI` and unregisters the connection (eech `comm_man.c:2445-2465`). (The pilot entity itself is destroyed via the client's own `set_pilot_entity (NULL)` TX destroy, F2; on timeout the server destroys it, below.) A client receiving END_GAME from the server exits with KICKOUT (eech `comm_man.c:2466-2476`); `PACKET_TYPE_SERVER_REJECTED` likewise (eech `comm_man.c:2483-2493`).
- **Timeout (connection validation)**: `validate_connections` (server only): if no traffic for `command_line_comms_timeout` seconds (+15 s grace while the connection has no pilot yet), send `PACKET_TYPE_CONNECTION_VALIDATION`; after **3** failed passes (`validation_count > 2`): reset the recorded gunship to `ENTITY_PLAYER_AI`, `destroy_client_server_entity (pilot_entity)` (which cascades F2 cleanup: seat, force roster, player-task, locks, quit message), free the connection's packets and unregister it (eech `commsserver.c:279-380`). Clients respond to validation with `PACKET_TYPE_CONNECTION_RESPONSE`, which zeroes the counter (eech `comm_man.c:1503-1529`).
- **Death/eject (task/pilot consequences)**: death does not destroy the pilot entity — the gunship is killed / reverts to AI and the career log records death+loss (F15/F20); the ejected flag only makes the airframe unselectable (F17). The player returns to the planner and may select a new mission; task completion state of the abandoned task evolves normally on the server.

Constants:

| Name | Value | Source |
|---|---|---|
| timeout base | `command_line_comms_timeout` s (command line) | eech `commsserver.c:303` |
| pre-pilot grace | +15 s | eech `commsserver.c:307` |
| validation passes before drop | 3 (`validation_count > 2`) | eech `commsserver.c:312` |

### PILOT-F24 — Per-pilot difficulty affects AI behaviour

Behavior: the difficulty stored on each pilot entity (from that player's local setting, F4) is read wherever AI reacts to *that specific player*: engage task generation (eech `ai/taskgen/engage.c:991-993`), vehicle target selection (eech `entity/mobile/vehicle/vh_tgt.c:1134`), vehicle weapon usage (eech `vh_wpn.c:700`), weapon damage (eech `entity/mobile/weapon/damage.c:649`), collision (eech `wn_cllsn.c:339`), decoy effectiveness (eech `wn_decoy.c:214`), group messages (eech `gp_msgs.c:395`), avionics events (eech `gunships/avionics/common/co_avevn.c:531`). So in MP each player fights AI tuned to their own difficulty.

### PILOT-F25 — AI pilot name generator (dead)

Behavior: side-specific first/last name tables (13×20 blue, 12×14 red — action-movie character names) with `create_new_pilot_name` picking randomly (eech `pi_name.c:84-207`). **No callers found** in the source tree — dead code ("temporary implementation" per comment eech `pi_name.c:79-82`).

## 4. Interactions

- **→ Task system (Spec: tasks)**: `INT_TYPE_TASK_SCORE` is filled by the kill-credit pipeline (F16) and paid out as experience at termination (F9); `counts_towards_player_log` gates career logging; `INT_TYPE_AWARDED_MEDALS`/`INT_TYPE_AWARDED_PROMOTION` are stored on the task for debrief; `LIST_TYPE_PLAYER_TASK` and `LIST_TYPE_PILOT_LOCK` link pilots into task lifetime; task destroy unlinks both.
- **→ AI task generation**: pilot locks and keysite reserve counts remove tasks from the AI assignment pool (F18), i.e. players *compete with the AI for missions* and the campaign deliberately holds missions back for humans.
- **→ Groups**: group `INT_TYPE_KILLS` aggregates member kills (F16); player possession toggles group weapons-hold/free (F20); group merge sums kills (eech `group.c:479-485`).
- **→ Forces**: pilots are FORCE children; force kill statistics updated per kill (eech `mobile.c:471-477`); session pilot count enumerates force pilot lists.
- **→ Session/UI**: high-score table drives the MP leaderboard UI; join/quit system chat messages; chat page pilot list refresh on pilot link.
- **← Entity comms layer**: all pilot state and career-relevant events replicate via `ENTITY_COMMS_*` messages (PILOT_REQUEST_ACCEPTED, PLAYER_KILL, PLAYER_TASK_COMPLETED/TERMINATED, TASK_KILL/LOSS, MOBILE_KILL) inside `PACKET_TYPE_AI_DATA`.
- **← Dynamics/damage**: purple heart reads dynamics damage flags; death logging keyed to landing assessment and `INT_TYPE_ALIVE`.
- **← Warzone data (GWUT)**: `counts_towards_player_log`, keysite assign/reserve task counts, vehicle map icons, entity `INT_TYPE_POINTS_VALUE` are data-driven inputs to this spec's formulas.

## 5. Port mapping

Per the port's stated architecture: the DCS port has **no pilots/promotions module and no MP/player layer module**; DCS World itself owns player slots, join/leave, side selection and aircraft occupancy (the port's live-validation checklist only verifies player slots exist).

| Feature | Status | Note |
|---|---|---|
| PILOT-F1 pilot entity create | NOT PORTED (handled natively by DCS) | DCS player slots replace pilot entities; no campaign-side pilot record exists. |
| PILOT-F2 pilot destroy/cleanup | NOT PORTED (handled natively by DCS) | Slot vacancy is DCS-native; no lock/task cleanup exists because locks/player-tasks aren't ported. |
| PILOT-F3 server pilot from player log | NOT PORTED | No player log in the port. |
| PILOT-F4 client pilot request/side selection | NOT PORTED (handled natively by DCS) | DCS slot selection determines side/airframe; no rank/difficulty payload. |
| PILOT-F5 join/quit announce, count, auto-pause | NOT PORTED (partially native) | DCS shows join/leave natively; EECH auto-pause-when-empty has no port equivalent. |
| PILOT-F6 session kills & high-score table | NOT PORTED | No leaderboard in the port. |
| PILOT-F7 player career log & persistence | NOT PORTED | No persistent pilot career in the port. |
| PILOT-F8 rank/promotion thresholds | NOT PORTED | Promotion table (0/7500/32000/120000/250000) unimplemented. |
| PILOT-F9 mission-termination awards | NOT PORTED | No experience/medal payout; task scoring itself is a task-module concern (see its spec). |
| PILOT-F10..F14 medals (valour/air/wings/purple heart/campaign) | NOT PORTED | Entire medal system absent. |
| PILOT-F15 career kill/death/weapon stats | NOT PORTED | DCS tracks per-mission stats natively but the port keeps no career log. |
| PILOT-F16 kill credit pipeline | UNKNOWN | Server-side kill→task-score credit may be partially represented in the port's task/scoring modules; player-log branches certainly not. Needs check against the task spec's module. |
| PILOT-F17 player-flyable filtering | NOT PORTED (handled natively by DCS) | DCS slotting enforces side/occupancy/alive natively; EECH's player-controllable whitelist is moot. |
| PILOT-F18 planner locks & AI reserve for players | NOT PORTED | No planner; AI task assignment in the port has no player-reservation concept (fidelity gap if human tasking is added). |
| PILOT-F19 player task assignment | NOT PORTED | No player-task link; players are not assigned campaign tasks. |
| PILOT-F20 gunship possession / PLAYER transitions | NOT PORTED (handled natively by DCS) | DCS owns aircraft occupancy; the campaign AI side of "hand a group member to a human" is absent. |
| PILOT-F21 MP gunship claim protocol | NOT PORTED (handled natively by DCS) | DCS slot system. |
| PILOT-F22 session join / state sync | NOT PORTED (handled natively by DCS) | DCS server replicates world state; the campaign script runs server-side only. |
| PILOT-F23 disconnect/timeout handling | NOT PORTED (handled natively by DCS) | DCS handles disconnects; no campaign-side pilot/task cleanup is needed until player tasking exists. |
| PILOT-F24 per-pilot difficulty | NOT PORTED | Port has a single campaign difficulty context at most; per-player AI tuning absent. |
| PILOT-F25 AI pilot names | NOT PORTED | Dead in EECH anyway. |

Most consequential gaps for the port: (1) no mechanism reserving campaign tasks for human players (F18) — in EECH the AI deliberately leaves missions for humans; (2) no player↔task assignment (F19) so humans cannot take campaign missions at all yet; (3) no kill→score→career loop (F9/F16), which in EECH is the player-facing reward spine of the campaign.

## 6. Open questions

1. **Flying-hours unit mismatch**: `get_player_log_flying_hours` divides seconds by `TIME_1_HOUR` (a millisecond constant = 3 600 000, eech `modules/system/timer.h:111`) while `award_aviator_wings` divides by `ONE_HOUR` (3600 s, eech `modules/maths/constant.h:166`). The UI-facing hours getter therefore appears to under-report by ×1000 (eech `player.c:740` vs `play_md.c:1018`). Intent unclear — likely a bug preserved in the community source.
2. **`get_player_weapon_log_hit` returns the FIRED counter** (eech `player.c:1117`) — copy-paste bug; hit statistics are recorded but unreadable through this accessor.
3. **Pilot entity `INT_TYPE_KILLS` writer**: the only found writer is the commented-out MP pilot-scoring block (eech `hc_msgs.c:255-297`). Whether any other live path increments a pilot entity's kills (making the high-score table non-static) was not located — possibly deathmatch-only code elsewhere or genuinely orphaned after the comment-out.
4. **Server trusts client-supplied rank/side/difficulty** in the pilot request (F4) — no validation server-side. Whether rank has any live gameplay effect beyond display (given `get_player_log_task_level` is uncalled) is unresolved: no rank-based mission filtering was found.
5. **Air medal on partial completion**: counter neither incremented nor reset (eech `helicop.c:786-808`) — so a partial preserves a success streak. Intent vs. oversight unknown.
6. **`ENTITY_COMMS_PLAYER_KILL` double-count risk**: the handler credits the log if *either* victim or aggressor is LOCAL (eech `en_comms.c:4513-4517`); when a LOCAL player is the victim this records a death (via the victim==gunship branch of `inc_player_log_kills`), but the message is also sent with `(aggressor, victim)` argument order from `mobile.c:457` and `(aggressor=…, receiver as victim)` from `hc_msgs.c:324` — exact death/kill attribution across machines deserves a trace before porting.
7. **`level[NUM_PLAYER_LEVELS]` array**: beyond the 5 TRAINING file-tag debug hooks (eech `player.c:374-378`) and `get/set_player_log_level` using only index 0, its purpose is unclear.
8. **Special game types** (deathmatch/cooperative referenced in comments, eech `pi_int.c:124-127`, dead block eech `hc_msgs.c:279`): the live session special-gametype rules (scoring −1 for coop friendly kills etc.) are commented out; whether any special-gametype pilot scoring survives elsewhere was not located.
