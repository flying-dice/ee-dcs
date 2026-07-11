# EECH Spec 09 — Warzone Data, Factions, Population & Road Network

Sources:
- `aphavoc/source/ai/faction/parser.c` (+ `parser.h`) — legacy warzone/campaign file parser (almost entirely `#if 0`)
- `aphavoc/source/ai/parser/parsgen.c` — the **live** campaign-file parser that superseded parser.c (cross-referenced where it changes behaviour)
- `aphavoc/source/ai/faction/faction.c` (+ `faction.h`) — faction creation, member/group spawning, frontline force placement
- `aphavoc/source/entity/special/force/fc_updt.c`, `force.c`, `force.h`, `entity/system/en_types/en_force.h` — force entity, periodic tick, reserves, campaign criteria structures
- `aphavoc/source/ai/faction/popread.c` (+ `popread.h`) — population model (sector sides, city/airfield/SAM placement)
- `aphavoc/source/ai/faction/routegen.c` (+ `routegen.h`) — airfield waypoint-route tree extraction from 3D objects
- `aphavoc/source/ai/ai_misc/ai_route.c` (+ `ai_route.h`), `ai/ai_misc/ai_misc.c`, `ai/highlevl/highlevl.c` — the road-node graph (data, readers, queries, node selection)
- `aphavoc/source/ai/faction/briefing.c` (+ `briefing.h`) — briefing/debriefing text generation

Dead-code notice: `parser.c`'s two parse functions are compiled out — `load_campaign_file` is wrapped in `#if 0` (`eech parser.c:141` … `#endif` at `eech parser.c:2140`) and the body of `load_campaign_object_population_data` is `#if 0` (`eech parser.c:2147-2968`). The schema is still fully visible and is captured below; where the live replacement (`parsgen.c`, called from `create_campaign` at `eech faction.c:146`) differs, both are cited. `fc_updt.c`'s server tick body is a single block comment (`eech fc_updt.c:86-495`) — the force entity's periodic update is a no-op in the shipped game.

## 1. Overview

This spec covers the data-driven skeleton of an EECH warzone:

1. **Campaign/warzone file schema** — a tag-based text script (read via `get_next_file_tag`) that declares map size, sector-ownership bitmap file, population placement file, factions, hardware reserves, task-generation toggles, regen frequency, frontline force counts, keysites, initial groups/members, scripted tasks, and (in the live parser) a full event/trigger scripting layer. Legacy schema in `parser.c` (dead), live schema in `parsgen.c`.
2. **Factions (forces)** — one `FORCE` entity per side holding registries, task-generation config, hardware reserve pools, kill/loss stats and campaign criteria. Periodic tick (campaign completion assessment every 5 s) exists only as dead code.
3. **Population model** — a PSD image gives per-sector initial ownership (red/blue by pixel colour) plus an optional "IMPORTANCE" layer; a binary placement file instantiates city templates, keysites (power station / radio / factory / port / military base / oil refinery), airbases/FARPs/carriers, and AAA/SAM sites.
4. **Road-node graph** — three binary files (`ROADS.dat`, `ROADS.nde`, `ROADS.wp`) define nodes, weighted links and per-link waypoint polylines. Consumed by frontline placement, ground-group advance/retreat, routed-vehicle movement and bridge destruction (link "breaks").
5. **Briefing generation** — a language-specific text database (`brief_en.dat` etc.) of per-task briefing/debriefing paragraphs with `GROUP`/`KEYSITE`/`POSITION`/`SECTOR`/`TARGET_TYPE`/`MEDAL`/`RANK` token substitution, plus medal/promotion/objective texts.

## 2. Data model

### 2.1 Force / faction

| Item | Definition | Notes |
|---|---|---|
| `struct FORCE` | `eech force.h:67-114` | Fields: `force_name` (max `STRING_TYPE_FORCE_NAME_MAX_LENGTH`); list roots `keysite_force_root`, `independent_group_root`, `pilot_root`, `division_root`, `campaign_objective_root`, `air_registry_root`, `ground_registry_root`, `sea_registry_root` (`eech force.h:72-81`); `task_generation[NUM_ENTITY_SUB_TYPE_TASKS]` (`eech force.h:87-88`); `campaign_criteria` linked list (`eech force.h:90-91`); `force_info_current_hardware[NUM_FORCE_INFO_CATAGORIES]` and `force_info_reserve_hardware[NUM_FORCE_INFO_CATAGORIES]` (`eech force.h:93-95`); `kills`/`losses`/`group_count` per group sub-type (`eech force.h:97-100`); `sector_count` (`eech force.h:102-103`); `sleep` timer (`eech force.h:105-106`); bitfields `force_attitude`, `colour`, `side` (`eech force.h:108-111`). |
| `enum FORCE_INFO_CATAGORIES` | `eech en_force.h:258-272` | `ARMED_FIXED_WING, UNARMED_FIXED_WING, ARMED_HELICOPTER, UNARMED_HELICOPTER, ARMED_ROUTED_VEHICLE, UNARMED_ROUTED_VEHICLE, ARMED_SHIP_VEHICLE, UNARMED_SHIP_VEHICLE` (8 categories). This is the granularity of the reserve pools. |
| `enum ENTITY_FORCE_ATTITUDE_TYPES` | `eech en_force.h:88-101` | `COWARD, PASSIVE, CAUTIOUS, NORMAL, FEISTY, AGGRESSIVE, DESTRUCTIVE, ERRATIC`. Set from the `FACTION` tag's `ATTITUDE` keyword. |
| `struct TASK_GENERATION_TYPE` | `eech en_force.h:240-252` | `valid:1` bitfield + `created/completed/failed` counters. |
| `struct CAMPAIGN_CRITERIA_TYPE` | `eech en_force.h:149-200` | `criteria_type, valid, result` (short ints); `rank_points, experience_points, *rank_variable, *experience_variable`; anonymous union: `{goal,count,type}` / `{days,hours,minutes,seconds}` / `{value1..value4}`; `next` pointer (linked list per force). |
| `enum CAMPAIGN_RESULT_TYPES` | `eech en_force.h:128-140` | `NONE, FAIL, SUCCESS, STALEMATE, OUTOFHARDWARE, SERVER_REJECTED`. |
| `enum CAMPAIGN_TRIGGER` | `eech en_force.h:206-231` | Live trigger types: `NONE, BALANCE_OF_POWER, TASK_COMPLETED, TASK_FAILED, OBJECT_DESTROYED, OBJECT_FIRED, OBJECT_TARGETED, OBJECT_LANDED, INEFFICIENT_KEYSITE, WAYPOINT_REACHED, SECTOR_WON, SECTOR_LOST, SECTOR_REACHED, TIME_DURATION, VARIABLE_CONDITION, RANDOM, USER_LANDED, KEY_PRESS`. |
| `CAMPAIGN_CRITERIA_*` enum | **not defined anywhere in the tree** | Symbols (`CAMPAIGN_CRITERIA_BALANCE_OF_POWER`, `_COMPLETED_TASKS`, `_FAILED_TASKS`, `_DESTROYED_ALLIED_OBJECTS`, `_DESTROYED_ENEMY_OBJECTS`, `_INEFFICIENT_ALLIED_KEYSITES`, `_INEFFICIENT_ENEMY_KEYSITES`, `_SURRENDERED_SIDES`, `_SECTOR_REACHED`, `_REACHED_WAYPOINTS`, `_TIME_DURATION`, `_CAPTURED_SECTORS`, `_LOST_SECTORS`, `_ENEMY_FIRED`, `_SPECIAL_KILLS`) appear only in dead code (`eech parser.c:1001-1179`, `eech fc_updt.c:190-298`); no live enum/`campaign_criteria_names[]` exists. The live game replaced criteria with the trigger/event system above. |
| `force_hardware_update` flag | `eech force.h:144-149` | Global gate on force bookkeeping (`set_/get_force_hardware_update`). |

### 2.2 Frontline placement

| Item | Definition | Notes |
|---|---|---|
| `enum FRONTLINE_FORCE_PLACEMENT_TYPES` | `eech faction.h:79-89` | `NONE, PRIMARY, SECONDARY, ARTILLERY`. |
| `struct FRONTLINE_FORCES_PLACEMENT_DATA` | `eech faction.h:95-104` | Bitfields per road node: `side : NUM_SIDE_BITS`, `route_node : NUM_ROUTE_NODE_BITS`, `force_placement_type : NUM_FRONTLINE_FORCE_TYPES`. One record per road node, allocated/freed inside `place_frontline_forces` (`eech faction.c:1368-1371`, freed `eech faction.c:1669-1671`). |

### 2.3 Road-node graph

| Item | Definition | Notes |
|---|---|---|
| `struct LINK_DATA` | `eech ai_route.h:98-109` | `int cost`; bitfields `node : 14` (target node id), `breaks : 5` (number of destroyed bridges on this link, 0 = passable, max 32 enforced at `eech ai_route.c:1082-1086`). |
| `struct NODE_DATA` | `eech ai_route.h:115-131` | Bitfields `node : 14` (id), `safe_radius : 14` (metres of deployable open ground), `number_of_links : 7`, `visited : 7`, `side_occupying : 2`, `side_aware : 2`, `side_exploring : 2`; plus `link_data *links`. |
| `struct NODE_LINK_DATA` | `eech ai_route.h:137-153` | `unsigned short source, destination, path_type, number_of_links; int padding; vec3d *link_positions` — the intermediate waypoint polyline for one link. |
| Globals | `eech ai_route.h:159-178`, `eech ai_route.c:109-131` | `road_nodes` (node array), `road_node_positions` (`vec3d` per node), `road_node_link_positions` (link polyline array), `total_number_of_road_nodes`, `total_road_node_link_count`, `road_nodes_loaded`; vestigial search scratch `best_cost`, `best_recurse_level`, `current_route[MAX_ROUTE_LENGTH]`, `best_route[MAX_ROUTE_LENGTH]`. |
| `MAX_ROUTE_LENGTH` | `eech ai_route.h:69` | 100. |
| File extensions | `eech ai_route.h:75-79` | node positions `.nde`, node/link data `.dat`, link polylines `.wp`. |

### 2.4 Routegen (airfield route trees)

| Item | Definition | Notes |
|---|---|---|
| `struct WAYPOINT_NODE` | `eech routegen.c:91-115` | `tree_depth, tree_number, node_index, number_of_children, number_of_parents, primary, start, possible_start, references, in_route, processed; vec3d position; parents[MAX_WAYPOINT_LINKS]; children[MAX_WAYPOINT_LINKS]`. |
| `struct ROUTE_WAYPOINT_POSITION` | `eech routegen.h:67-80` | `number_of_positions; vec3d position` (position of slot 0 at that depth); `vec3d *offsets` (per-slot offsets relative to slot 0). Output table indexed by tree depth. |
| Limits | `eech routegen.c:81-85` | `MAX_WAYPOINT_NODES` 768, `MAX_WAYPOINT_LINKS` 24, `MAX_WAYPOINT_STARTS` 24. |

### 2.5 Population model

| Item | Definition | Notes |
|---|---|---|
| `enum TEMPLATE_TYPE` | `eech popread.c:89-130` | `INVALID, SPACE, HOUSING, OFFICE, INDUSTRY, CULTURAL, CHURCH, OUTSKIRTS, AIRFIELD, AAASAM, PORTSE, PORTNW, MILITARY, FARM, OIL, KEY_POWER, KEY_RADIO, KEY_INDUSTRY, KEY_PORT, KEY_MILITARY, KEY_OIL, CONSTRUCT, RUIN, WATER, ROAD_X, ROAD_JUNC_N, ROAD_JUNC_S, ROAD_JUNC_E, ROAD_JUNC_W, ROAD_CROSS, ROAD_Z, ROAD`. |
| `struct TEMPORARY_TEMPLATE` | `eech popread.c:136-154` | `number_of_objects; template_type type; approximation_object, base_object, routes_object` (3D object indices); `objects*`. |
| `struct TEMPORARY_TEMPLATE_OBJECT` | `eech popread.c:160-172` | `object_index; float x, y, heading` (heading converted to radians on read, `eech popread.c:873`). |
| `struct TROOP_LANDING_ROUTE_INFORMATION` | `eech popread.c:178-195` | Per-3D-object troop landing/takeoff polylines: node counts, `vec3d *landing_route/*takeoff_route`, `landing_position`, `heading`, `landing_position_valid`. Table `object_3d_troop_routes[OBJECT_3D_LAST]` (`eech popread.c:331-332`, init `eech popread.c:4331-4354`). |
| Sector side cache | `eech popread.c:280-285` | `current_initial_sector_sides` — copy of the background PSD layer, sized `(MAX_MAP_X_SECTOR+1) × (MAX_MAP_Z_SECTOR+1)`; queried via `get_initial_sector_side` (`eech popread.c:557-584`). |
| `population_importances` | `eech popread.c:334-335`, filled `eech popread.c:520-551` | `int` per sector from the "IMPORTANCE" PSD layer's red channel (row-flipped). Consumed with inverted sense: `important = importance_value ? FALSE : TRUE` (`eech popread.c:1113-1121`, `eech popread.c:1942-1951`). |
| Carrier names | `eech popread.c:287-326` | 14 blue (`USS TARAWA` …), 17 red (`BODRY` …) fixed carrier keysite names. |

### 2.6 Briefing

| Item | Definition | Notes |
|---|---|---|
| `MAX_NUMBER_OF_MISSION_TEXTS` | `eech briefing.h:67` | 30 texts per slot. |
| `struct TASK_BRIEFING_TYPE` | `eech briefing.h:73-95` | Per task sub-type: counts + arrays for `briefing_text1/2/3`, `debriefing_text_success/partial/failure`. |
| `enum EXTRA_BRIEFING_TYPES` | `eech briefing.h:108-115` | `MEDAL, PROMOTION, OBJECTIVES`. |
| `struct EXTRA_BRIEFING_TYPE` | `eech briefing.h:123-142` | `type, sub_type` (medal bitmask / keysite sub-type), `text_count`, `briefing_text[30]`, `next` (linked list). |
| `struct BRIEFING_SUBSTITUTION_TYPE` | `eech briefing.c:87-99` | `{string, position_ptr, function}` — token substitution table. |
| Brief file per language | `eech briefing.c:142-152` | `brief_en.dat, brief_fr.dat, brief_de.dat, brief_it.dat, brief_sp.dat, brief_rs.dat, brief_pl.dat`, loaded from `..\common\data\` (`eech briefing.c:81`, `eech briefing.c:243-245`). |

## 3. Features

---

### WARZONE-F1 — Warzone/campaign file: master tag schema

**Behaviour.** The campaign is described by a tag script. The legacy parser (`load_campaign_file`, `eech parser.c:142-2139`, ALL `#if 0`) and the live parser (`parser_campaign_file`, `eech parsgen.c`, invoked from `create_campaign` at `eech faction.c:146` with `<data_path>\<campaign_directory>\<campaign_filename>`) recognise the following top-level tags. Each row: keyword → entity/field populated.

Legacy `parser.c` tags (schema visible in dead code):

| Tag | Handler | Populates | Status in parser.c |
|---|---|---|---|
| `FILE_TAG_CAMPAIGN_DATA` | `eech parser.c:240-601` | see F2 | `#if 0` |
| `FILE_TAG_IF` / `FILE_TAG_ENDIF` | `eech parser.c:203-239` | conditional skip on player-log variable | comment-disabled inside dead code |
| `FILE_TAG_START_BASE` | `eech parser.c:603-629` | random pick of player start keysite on own side (`set_base_current_keysite`, reservoir-sampled `rand16 () % start_base_count`, `eech parser.c:612-623`) | comment-disabled |
| `FILE_TAG_OPTION_INVULNERABLE` / `_INFINITE_FUEL` / `_INFINITE_WEAPONS` / `_SUPPRESS_AI_FIRE` | `eech parser.c:631-705` | session `INT_TYPE_INVULNERABLE` / `INT_TYPE_INFINITE_FUEL` / `INT_TYPE_INFINITE_WEAPONS` / `INT_TYPE_SUPPRESS_AI_FIRE` | comment-disabled |
| `FILE_TAG_TOUR_OF_DUTY` (`HOURS`/`MINUTES`/`SECONDS`) | `eech parser.c:707-751` | session `FLOAT_TYPE_TOUR_OF_DUTY_TIME` | comment-disabled |
| `FILE_TAG_TIME` (h m s floats) | `eech parser.c:753-776` | session `FLOAT_TYPE_TIME_OF_DAY` | comment-disabled |
| `FILE_TAG_WEATHER` (`POSITION`, `VELOCITY`, `RADIUS`) | `eech parser.c:778-820` | session `VEC3D_TYPE_WEATHER_POSITION/VELOCITY`, `FLOAT_TYPE_RADIUS` | comment-disabled |
| `FILE_TAG_AUTO_ASSIGN_GUNSHIP` | `eech parser.c:822-839` | session `INT_TYPE_AUTO_ASSIGN_GUNSHIP` | in dead fn (live at `eech parsgen.c:426-443`) |
| `FILE_TAG_FLIGHT_DYNAMICS` (`TYPE <dynamics_option> <0/1>` list) | `eech parser.c:841-874` | bit-OR into `parser_flight_dynamics_options` (`1 << option_type`, `eech parser.c:863`) | in dead fn |
| `FILE_TAG_PLANNER_DATA` (`POSITION`, `ZOOM`) | `eech parser.c:876-915` | planner map viewpoint (calls themselves commented out) | in dead fn |
| `FILE_TAG_DATE` (day month year) | `eech parser.c:917-946` | session `INT_TYPE_DAY/MONTH/YEAR` | comment-disabled |
| `FILE_TAG_CAMPAIGN_CRITERIA` | `eech parser.c:948-1214` | see F10 | comment-disabled |
| `FILE_TAG_TASK_GENERATION` | `eech parser.c:1217-1272` | see F5 | in dead fn |
| `FILE_TAG_HARDWARE_RESERVES` | `eech parser.c:1274-1313` | see F4 | in dead fn |
| `FILE_TAG_TITLE` | `eech parser.c:1315-1330` | reads a 256-char string; discarded | in dead fn |
| `FILE_TAG_FACTION` | `eech parser.c:1332-1381` | see F3 | in dead fn |
| `FILE_TAG_REGEN_FREQUENCY` | `eech parser.c:1382-1424` | see F6 | in dead fn |
| `FILE_TAG_FRONTLINE_FORCES` | `eech parser.c:1426-1493` | see F9 | in dead fn |
| `FILE_TAG_KEYSITE` | `eech parser.c:1495-1552` | see F7 | in dead fn |
| `FILE_TAG_FLAG_PYLONS` | `eech parser.c:1554-1575` | int flag; `faction_place_pylons()` commented out — no effect | in dead fn |
| `FILE_TAG_CREATE_MEMBERS` | `eech parser.c:1577-1726` | see F7 | in dead fn |
| `FILE_TAG_CREATE_GROUP` | `eech parser.c:1728-1815` | see F7 | in dead fn |
| `FILE_TAG_CREATE_TASK` | `eech parser.c:1817-2029` | see F8 | in dead fn |
| `FILE_TAG_SAVED_CAMPAIGN` (`PATH`, `FILENAME`) | `eech parser.c:2031-2114` | load & `unpack_session` of a packed `.sav` buffer; version check `server_version_number == client_version_number` else `debug_fatal` (`eech parser.c:2083-2093`) | in dead fn |
| `FILE_TAG_SHORT_TEXT_START` / `LONG_TEXT_START` / `TEXT_END` | `eech parser.c:2116-2122` | ignored | in dead fn |
| `FILE_TAG_END` | `eech parser.c:2124-2130` | close file, return | in dead fn |

Live-only tags added in `parsgen.c` (line numbers are the `case` labels):

| Tag | Line | Populates |
|---|---|---|
| `FILE_TAG_ECHO_MESSAGE` | `eech parsgen.c:328` | debug log |
| `FILE_TAG_END_CAMPAIGN <result>` | `eech parsgen.c:344` | reads a `campaign_result_names` enum (result value read then unused in fragment) |
| `FILE_TAG_WHILE` / `FILE_TAG_END_WHILE` | `eech parsgen.c:357`, `:383` | script loop (file-offset based, `add_while_loop`) |
| `FILE_TAG_CALCULATE` | `eech parsgen.c:446` | arithmetic on two sub-expressions via `calulate_operator` |
| `FILE_TAG_IF`/`FILE_TAG_ELSE`/`FILE_TAG_ENDIF` | `eech parsgen.c:470/507/524` | conditional (recursive sub-parse of value1 op value2, `if_file_tag_operator`) |
| `FILE_TAG_CREATE_VARIABLE` / `FILE_TAG_SET_VARIABLE` / `FILE_TAG_VARIABLE` / `FILE_TAG_VALUE` | `eech parsgen.c:530/872/905/893` | named int script variables (`register_file_tag_variable`) |
| `FILE_TAG_CALL` / `FILE_TAG_FILENAME` | `eech parsgen.c:555/567` | invoke sub-expression / sub-file |
| `FILE_TAG_EVENT` / `FILE_TAG_CREATE_EVENT` / `FILE_TAG_END_EVENT` / `FILE_TAG_SET_EVENT_TRIGGERED` | `eech parsgen.c:586/612/933/844` | named script events stored as file offsets (`add_campaign_event`); `SET_EVENT_TRIGGERED <name> VALUE <int>` sets `event->triggered` |
| `FILE_TAG_CREATE_TRIGGER` | `eech parsgen.c:640-842` | see F10 (live) |
| `FILE_TAG_FORCE_NAME` | `eech parsgen.c:947` | force `STRING_TYPE_FORCE_NAME` |
| `FILE_TAG_CAMPAIGN_REQUIRES_APACHE_HAVOC <0/1>` | `eech parsgen.c:960` | session `INT_TYPE_CAMPAIGN_REQUIRES_APACHE_HAVOC` |
| `FILE_TAG_MEDAL <medal_type>` | `eech parsgen.c:981` | session `INT_TYPE_CAMPAIGN_MEDAL` (campaign-completion medal) |
| `FILE_TAG_WEATHER_RAIN <0/1>` | `eech parsgen.c:1295` | 0 → `set_session_fixed_weather_mode (…, WEATHERMODE_DRY)` (`eech parsgen.c:1307-1311`) |
| `FILE_TAG_WEATHER_WIND <float>` | `eech parsgen.c:1318` | read + logged only |
| `FILE_TAG_START_BASE` | `eech parsgen.c:1331` | counts candidate start bases (`start_base_count++`); the actual `set_base_current_keysite` calls are commented out (`eech parsgen.c:1341-1352`) |
| `FILE_TAG_DIVISION_ID_LIST <side> {TYPE <division> LIST n n … -1}*` | `eech parsgen.c:1524-1583` | `add_division_id_data (side, sub_type, count, number_list)`; max 128 ids per list (`eech parsgen.c:1562-1567`) |
| `FILE_TAG_VERSION_NUMBER <int>` | `eech parsgen.c:2171` | read + logged only |
| `FILE_TAG_SEASON <int>` | `eech parsgen.c:2189` | `set_global_season` (winter/summer camo) |
| `FILE_TAG_SAVED_CAMPAIGN` (`PATH`, `PATH`, `FILENAME`) | `eech parsgen.c:2209-2279` | as legacy but with campaign-directory path and `.sav` filename derivation (`eech parsgen.c:2243-2253`) |

**Trigger/cadence.** Parsed once at campaign creation (`create_campaign`, `eech faction.c:111-158`), server-side only (`ASSERT get_comms_model () == COMMS_MODEL_SERVER`, `eech faction.c:124`).

---

### WARZONE-F2 — `CAMPAIGN_DATA` section (map, files, factions, route data)

**Behaviour** (legacy `eech parser.c:240-601`; live `eech parsgen.c:1002-1293`). Ordered sub-schema:

1. `FILENAME <side-data file>` → `side_data_filename` (`eech parser.c:273-295`). At load: name containing `"SID"` → `read_sector_side_file` (PSD, F14); containing `"DAT"` → `load_ai_sector_data` (`eech parser.c:464-473`, `eech parsgen.c:1257-1266`).
2. optional `FILENAME <population placement file>` → `population_placement_filename` (`eech parser.c:301-327`), read via `read_population_placement_file` (F15) if present (`eech parser.c:481-485`, `eech parsgen.c:1272-1276`).
3. `MAP_X_SIZE <int>`, `MAP_Z_SIZE <int>`, `MAP_SECTOR_SIZE <int>` → `set_entity_world_map_size (x, z, sector_size)` (`eech parser.c:329-347`).
4. Live only: optional `MAP_X_MIN/MAP_Z_MIN/MAP_X_MAX/MAP_Z_MAX <float>` → session `FLOAT_TYPE_POPULATION_X_MIN/_X_MAX/_Z_MIN/_Z_MAX` (population/playable area bounds; defaults to full map) (`eech parsgen.c:1105-1145`, `eech parsgen.c:1212-1215`).
5. Legacy only: optional third `FILENAME <campaign object population file>` → `campaign_population_filename` → `load_campaign_object_population_data` (F2a below) (`eech parser.c:353-379`, `eech parser.c:495-499`). In the live parser this block is commented out and the call disabled (`eech parsgen.c:1149-1171`, `eech parsgen.c:1286-1290`).
6. AI reinitialisation: `create_local_only_entities (PACK_MODE_SERVER_SESSION)`, `reinitialise_ai_system ()`, `load_route_data ()` (loads road graph, F20) (`eech parser.c:387-391`, `eech parsgen.c:1179-1183`).
7. Session entity created if absent, with random weather mode (`eech parser.c:401-416`, `eech parsgen.c:1193-1206`).
8. `FACTION SIDE <entity_side> COLOUR <sys_colour>` repeated → `create_faction (side, colour)` (F3) (`eech parser.c:422-452`, `eech parsgen.c:1221-1247`).
9. Legacy: `initialise_ai_sectors ()` then side file, `initialise_node_awareness ()` (`eech parser.c:458-479`). Live parser drops the explicit `initialise_ai_sectors`/`initialise_node_awareness` calls at this point (`eech parsgen.c:1249-1266`).
10. Legacy only: optional per-movement route databases: `AIR_NODE_ROUTE_DATA <name>` → air route node files (`eech parser.c:501-522`); `ROAD_NODE_ROUTE_DATA <name>` → road node/positions/link-position files + `read_road_route_data` (`eech parser.c:528-548`); `RIVER_NODE_ROUTE_DATA` commented out (`eech parser.c:553-575`); `SEA_NODE_ROUTE_DATA <name>` (`eech parser.c:576-594`). Not present in the live `CAMPAIGN_DATA` handler — the live game always loads `ROADS`/`ROADDATA` from the session data path (F20).

**F2a — campaign object population sub-file schema** (`load_campaign_object_population_data`, body `#if 0` at `eech parser.c:2145-2969`; also invoked recursively per traffic route file at `eech parser.c:2704`):

| Tag | Populates |
|---|---|
| `FILE_TAG_IF/ENDIF` | conditional on player-log variable (`eech parser.c:2179-2213`) |
| `FILE_TAG_BUILDING TYPE <entity_type> OBJECT_NUMBER <3d-object> HEADING <deg> POSITION <x y z> [RADIUS <scale>] [SIDE <side>]` | inside a keysite: `ENTITY_TYPE_SITE` building added to keysite `LIST_TYPE_BUILDING_GROUP`, position relative to keysite, clamped to terrain height (`eech parser.c:2276-2307`); outside: `ENTITY_TYPE_SCENIC` with explicit `SIDE` (`eech parser.c:2308-2327`). Optional trailing `FILE_TAG_REGEN <regen_sub_type> <timer>` creates an `ENTITY_TYPE_REGEN` parented to force + closest landing-route waypoint, `FLOAT_TYPE_FREQUENCY = timer`, and moves the building under the regen (`eech parser.c:2331-2417`). |
| `FILE_TAG_SCENIC_OBJECT OBJECT_NUMBER … HEADING … POSITION … OBJECT_SCALING <x y z>` | `ENTITY_TYPE_OBJECT` sub-type `ENTITY_SUB_TYPE_FIXED_SCENIC_OBJECT` (`eech parser.c:2428-2481`) |
| `FILE_TAG_TERRAIN_OBJECT TYPE … OBJECT_NUMBER … HEADING … POSITION …` | raw 3D instance inserted into terrain, no entity (`eech parser.c:2483-2550`) |
| `FILE_TAG_KEYSITE <keysite_sub_type> NAME <string> SIDE <side> POSITION <x y z>` | `ENTITY_TYPE_KEYSITE` parented to force `LIST_TYPE_KEYSITE_FORCE`, y snapped to terrain (`eech parser.c:2552-2624`) |
| `FILE_TAG_KEYSITE_END` | clears parser keysite context (`eech parser.c:2626-2632`) |
| `FILE_TAG_TRAFFIC_ROUTE TYPE <landing_sub_type> COUNT <total_landing_sites> FILENAME <route file>` | `ENTITY_TYPE_LANDING` child of keysite (`LIST_TYPE_LANDING_SITE`) at keysite position with `INT_TYPE_TOTAL_LANDING_SITES`; ORs `1 << type` into keysite `INT_TYPE_LANDING_TYPES`; recursively parses `<data_path>\route\<file>` (`eech parser.c:2634-2713`) |
| `FILE_TAG_ROUTE TYPE <task_sub_type> COUNT <n>` then per waypoint `TYPE <wp_sub_type> FORMATION <formation> POSITION <x y z> VELOCITY <v> RADIUS <r>` | waypoints appended to the landing entity's task route (`get_local_landing_entity_task`); positions relative to landing entity, y bounded to ≥ terrain (`eech parser.c:2715-2952`); `validate_landing_route` at end (`eech parser.c:2950`). Waypoint `CRITERIA`, velocity/radius storage and terrain-check flags are comment-disabled (`eech parser.c:2806-2824`, `:2844-2848`). |

**Constants**

| Name | Value | Source |
|---|---|---|
| regen closest-waypoint initial best range | 10000000 | eech parser.c:2364 |
| `regen_frequency_modifier` defaults | 1.0 / 1.0 (blue/red) | eech parser.c:132-134 (in commented `initialise_parser`) |

---

### WARZONE-F3 — Faction declaration

**Behaviour.** Inside `CAMPAIGN_DATA`, `FACTION SIDE <side> COLOUR <colour>` calls `create_faction` which creates one `ENTITY_TYPE_FORCE` under the session with `INT_TYPE_COLOUR` and `INT_TYPE_SIDE` (`eech faction.c:234-261`). A later top-level `FACTION SIDE <side> COLOUR <colour> ATTITUDE <attitude>` block re-selects that force as parser context and sets `INT_TYPE_FORCE_ATTITUDE` (`eech parser.c:1332-1381`; live `eech parsgen.c:1449-1498`); undefined faction → `debug_fatal` (`eech parser.c:1364`). Legacy parser also called `create_frontline (force)` here (`eech parser.c:1369`); the live parser has that call commented out (`eech parsgen.c:1486`). `clear_factions` unlinks all keysites from every force (`eech faction.c:209-228`); `destroy_campaign` frees the three data filenames and reinitialises route data (`eech faction.c:164-203`).

---

### WARZONE-F4 — Hardware reserve seeding & consumption

**Behaviour.** `HARDWARE_RESERVES` (must follow a `FACTION` block): repeated `TYPE <force_info_catagory> COUNT <int>` sets `force_raw->force_info_reserve_hardware[hardware_type] = count` — the reserve seeding at `eech parser.c:1303` (dead) and identically live at `eech parsgen.c:1426`.

Consumption/bookkeeping (live):
- `add_to_force_info` increments `force_info_current_hardware[cat]` for every mobile added; if `get_game_status () == GAME_STATUS_INITIALISED` (i.e. after campaign load, in play) it also decrements `force_info_reserve_hardware[cat]` (`eech force.c:211-243`). Gated by `force_hardware_update` flag (`eech force.c:226-230`).
- Regeneration is blocked when the pool is empty: regen update reads `reserve_count = force_raw->force_info_reserve_hardware[aircraft_database|vehicle_database[sub_type].force_info_catagory]` and returns NULL if `<= 0` (`eech rg_updt.c:284-297`).
- The dead force tick computed balance-of-power from `force_info_current_hardware` summed over all 8 categories for both sides (`eech fc_updt.c:148-162`).

**Constants**

| Name | Value | Source |
|---|---|---|
| Number of reserve pools | 8 (`NUM_FORCE_INFO_CATAGORIES`) | eech en_force.h:258-270 |
| Reserve decrement condition | game status == INITIALISED | eech force.c:238-242 |

---

### WARZONE-F5 — Task generation configuration

**Behaviour.** `TASK_GENERATION` after a `FACTION` block.
- Legacy schema (dead): repeated `TYPE <task_sub_type> <duration> <frequency%> <urgency%>`; stores `task_generation[type].valid = TRUE`, `.duration` (asserted 0..48 h), `.frequency = value/100` (0..1), `.urgency = value/100` (0..1) (`eech parser.c:1217-1272`, asserts `eech parser.c:1246-1254`).
- Live schema: repeated `TYPE <task_sub_type> <0|1>`; stores only `task_generation[type].valid` (`eech parsgen.c:1359-1395`). Duration/frequency/urgency fields no longer exist in the live struct — `TASK_GENERATION_TYPE` now carries `valid` plus created/completed/failed counters (`eech en_force.h:240-252`), consumed by the task generator (`ai/taskgen`).

**Constants**

| Name | Value | Source |
|---|---|---|
| duration bound (legacy) | 0 .. 48 * ONE_HOUR | eech parser.c:1246 |
| frequency/urgency scale (legacy) | input / 100 → 0..1 | eech parser.c:1248-1254 |

---

### WARZONE-F6 — Regen frequency

**Behaviour.** `REGEN_FREQUENCY <float>` after a `FACTION` block.
- Legacy (dead): reads a *modifier*; stores in `regen_frequency_modifier[side]` and rewrites every existing regen's `FLOAT_TYPE_FREQUENCY = regen_update_frequency / modifier` walking force → keysites → regens (`eech parser.c:1382-1424`).
- Live: reads an absolute per-side frequency into `regen_frequency[side]` (`eech parsgen.c:1500-1522`; ASSERT > 0 at `eech parsgen.c:1513`), declared at `eech regen.h:174`. Regen tick then sleeps `regen_frequency[side] * get_regen_frequency_difficulty_modifier ()` between spawn attempts (`eech rg_updt.c:176-183`).

---

### WARZONE-F7 — Keysite selection, supplies, and initial unit creation

**Behaviour.** A `KEYSITE` block sets pending context (no entity is created here — keysites already exist from the population pass, F15/F16):
`KEYSITE <keysite_sub_type> NAME <name> {TYPE <landing_sub_type>}* AMMO_SUPPLIES <float> FUEL_SUPPLIES <float>` (`eech parser.c:1495-1552`; live `eech parsgen.c:1664-1721`). Landing types are ORed to a `required_landing_types` bitmask; duplicate type asserts (`eech parser.c:1528`).

`CREATE_MEMBERS GROUP <group_sub_type> MEMBER <aircraft|vehicle sub_type> COUNT <n> [MOBILE_KEYSITE FORMATION_COMPONENT <formation_component>]` (`eech parser.c:1577-1726`; live `eech parsgen.c:1723-1872`):
- Member enum table chosen by group registry: air registry → aircraft names, otherwise vehicle names (`eech parser.c:1601-1619`; live keys off `registry_list_type`, `eech parsgen.c:1747-1765`).
- If no keysite context, scans the faction's keysite list for `(sub_type == keysite_type) && (IN_USE == FALSE) && (SIDE == faction_side) && name match (case-insensitive)`; on match sets `FLOAT_TYPE_AMMO_SUPPLY_LEVEL`/`FLOAT_TYPE_FUEL_SUPPLY_LEVEL` from the pending KEYSITE block (`eech parser.c:1627-1675`; live `eech parsgen.c:1773-1821`). Not found → `debug_fatal` (`eech parser.c:1680`).
- `MOBILE_KEYSITE` variant: `create_faction_members` at the keysite position and links the first member as the keysite's `LIST_TYPE_MOVEMENT_DEPENDENT` parent (a moving keysite, e.g. carrier) (`eech parser.c:1683-1704`).
- Otherwise `create_landed_faction_members` (F7a). Parser member context set to the group's first member (used by `CREATE_TASK`).

`CREATE_GROUP GROUP <group_sub_type> TYPE <formation_component>` — same keysite search, then `create_landed_faction_group` (`eech parser.c:1728-1815`; live `eech parsgen.c:1874-1965`).

**F7a — landed member creation** (`create_landed_faction_members`, `eech faction.c:267-490`): parent is force for `LIST_TYPE_INDEPENDENT_GROUP` groups else keysite (`eech faction.c:313-322`); requires the keysite's landing entity for the group's `default_landing_type` (`eech faction.c:332`); walks the landing route to the final (landed) waypoint (`eech faction.c:341-347`); creates `ENTITY_TYPE_GROUP` with `VERBOSE_OPERATIONAL_STATE_WAITING` (`eech faction.c:360-370`); per member: first free formation slot from the `INT_TYPE_LANDED_LOCK` bitmask (`eech faction.c:399-405`), spawn via `create_mobile_member` state `OPERATIONAL_STATE_LANDED`, undercarriage down (`eech faction.c:407-419`), position from `get_local_waypoint_formation_position`, y snapped to terrain except at `ENTITY_SUB_TYPE_KEYSITE_ANCHORAGE` (`eech faction.c:433-438`), attitude from terrain normal + keysite heading + fuselage angle (`eech faction.c:450-462`), then `ENTITY_MESSAGE_LOCK_LANDING_SITE` (`eech faction.c:476`). First use marks keysite `IN_USE = TRUE` and updates imap sector side, importance and distance-to-friendly-base (`eech faction.c:383-393`).

**F7b — landed group creation** (`create_landed_faction_group`, `eech faction.c:496-772`): as F7a but member types come from a formation-component table — blue members `components[loop*2]`, red `components[loop*2+1]` (`eech faction.c:658-667`); overfilling landing slots → `debug_fatal` (`eech faction.c:640-652`); FARP members get heading toward the previous route waypoint instead of keysite heading (`eech faction.c:712-722`).

**F7c — in-flight/landing member creation** (`create_landing_faction_members`, `eech faction.c:778-1054`, used by regen at runtime): requires `free_sites - INT_TYPE_RESERVED_LANDING_SITES > 0` where `free_sites = TOTAL_LANDING_SITES - bitcount (LANDED_LOCK)` (`eech faction.c:860-864`); slot search also honours `LANDING_LOCK` modulo the landing formation size (`eech faction.c:872-895`); groups created client-server under `LIST_TYPE_KEYSITE_GROUP`, members state `OPERATIONAL_STATE_TAXIING`, `FLOAT_TYPE_MAIN_ROTOR_RPM = 60.0` (`eech faction.c:1004`), locks landing site *and* route (`eech faction.c:1006-1008`), and `add_group_to_division` (`eech faction.c:1038`).

**F7d — generic member creation** (`create_faction_members`, `eech faction.c:1060-1317`): asserts `number <= group max member count && <= 12` (`eech faction.c:1106`); ground-registry groups refuse non-land terrain (`eech faction.c:1138-1146`); spread radius `radius = max (min (safe_radius − 5, formation_radius), 5)` using the nearest road node's safe radius (`eech faction.c:1191-1197`, scaling `eech faction.c:1241-1255`); routed vehicles get pseudo-random heading `rad ((index²) % 360)` (`eech faction.c:1277`). `create_mobile_member` dispatches by entity type (anti-aircraft / fixed-wing / helicopter / routed vehicle / ship / person), local-only in AI-tool mode, else client-server (`eech faction.c:1678-1820`).

**Constants**

| Name | Value | Source |
|---|---|---|
| max members per created group | 12 (`FORMCOMP` limit) | eech faction.c:1106 |
| routed-vehicle spread min radius | 5.0 m | eech faction.c:1197 |
| safe-radius margin | safe_radius − 5 | eech faction.c:1195 |
| initial rotor RPM (landing spawn) | 60.0 | eech faction.c:1004 |

---

### WARZONE-F8 — Scripted initial tasks (`CREATE_TASK`)

**Behaviour** (`eech parser.c:1817-2029`; live `eech parsgen.c:1967-2168`). Requires a parser member (from `CREATE_MEMBERS`). Schema:
`CREATE_TASK TYPE <task_sub_type> SIDE <side> MOVEMENT <movement_type> <start_time> <stop_time> <expire_time> CREATE_WAYPOINT COUNT <n> { TYPE <wp_sub_type> POSITION <x y z> [RADIUS <r>] [DELTA_TIME <sec>] }* TEXT_END`.
- `DELTA_TIME` stored as `int * TIME_1_SECOND` (`eech parser.c:1957`); `RADIUS` read but the waypoint attribute is comment-disabled (`eech parser.c:2012`); `CRITERIA` disabled (`eech parser.c:1931-1941`).
- `create_task` is called with the group, priority literal `10.0`, first wp position/type, formation `FORMATION_5_ROW_LEFT` legacy / `FORMATION_ROW_LEFT` live, `&terminator_point` (`eech parser.c:1974-1982`; live `eech parsgen.c:2123-2135`). `start_time`/`stop_time` are read but not passed.
- Waypoints created as `ENTITY_TYPE_WAYPOINT` children with `POSITION_TYPE_ABSOLUTE` (`eech parser.c:1997-2018`).
- Task pushed onto the group stack and assigned to all members (`TASK_ASSIGN_ALL_MEMBERS`, `eech parser.c:2024-2026`).

---

### WARZONE-F9 — Frontline force placement

**Behaviour.** `FRONTLINE_FORCES <force_size>` (must follow `FACTION`): if > 0, calls `place_frontline_forces (force, force_size)` and then seeds attack-helicopter groups at every in-use FARP (`eech parser.c:1426-1493`; live `eech parsgen.c:1585-1662`).

FARP seeding differs: legacy alternates scout/recon attack-helicopter groups per FARP (`counter & 0x1`, `eech parser.c:1463-1476`); live cycles a 4-phase pattern (`counter & 0x03`): 0 → recon-attack + assault, 1 → attack (light A) + recon-attack, 2 → attack (light A) + assault, 3 → recon-attack only (`eech parsgen.c:1620-1649`).

`place_frontline_forces` (`eech faction.c:1323-1672`), road-graph-driven:
1. No-op unless road nodes loaded (`eech faction.c:1354-1357`).
2. Allocates one `frontline_forces_placement_data` per road node; each node's `side` = owning sector side via `get_local_sector_entity (&road_node_positions[node])` (`eech faction.c:1376-1381`).
3. **Primary pass**: own-side nodes with any link whose far node is enemy-side → `FRONTLINE_FORCE_PRIMARY` (boundary nodes) (`eech faction.c:1387-1420`).
4. **Secondary pass**: own-side, unmarked link-neighbours of PRIMARY nodes → `FRONTLINE_FORCE_SECONDARY` (`eech faction.c:1426-1464`).
5. **Artillery pass**: own-side, unmarked link-neighbours of SECONDARY nodes → `FRONTLINE_FORCE_ARTILLERY` (`eech faction.c:1470-1508`).
6. **Placement** at each marked node (skipped unless inside adjusted map area AND population area, `eech faction.c:1531`, `:1570`, `:1616`):
   - PRIMARY: `number = (int)(safe_radius / 4.0 + sfrand1 () * 2.0)`, bounded 1..force_size; formation `FORMATION_COMPONENT_PRIMARY_FRONTLINE_GROUP`, group type `ENTITY_SUB_TYPE_GROUP_PRIMARY_FRONTLINE` (`eech faction.c:1540-1550`).
   - SECONDARY: same count formula; `FORMATION_COMPONENT_SECONDARY_FRONTLINE_GROUP` / `ENTITY_SUB_TYPE_GROUP_SECONDARY_FRONTLINE` (`eech faction.c:1579-1589`).
   - ARTILLERY: alternates `FORMATION_COMPONENT_MLRS_GROUP` / `FORMATION_COMPONENT_ARTILLERY_GROUP` via a flip-flop `mlrs_flag` (`eech faction.c:1624-1633`); `number = (int)(safe_radius / 5.0)` bounded 1..min(force_size, component count) (`eech faction.c:1640-1644`).
   - All: parent keysite = closest keysite any type within search seeded at `1.0 * KILOMETRE` (`eech faction.c:1546`, ASSERT found); on success group `INT_TYPE_ROUTE_NODE = node` and `road_nodes[node].side_occupying = side` (`eech faction.c:1552-1557`).

**Constants**

| Name | Value | Source |
|---|---|---|
| primary/secondary group size | safe_radius/4 + sfrand1()*2, bound [1, force_size] | eech faction.c:1540-1542 |
| artillery group size | safe_radius/5, bound [1, min(force_size, component count)] | eech faction.c:1640-1644 |
| keysite search radius seed | 1 km | eech faction.c:1546 |
| MLRS/artillery alternation | flip-flop per artillery node | eech faction.c:1514, 1624-1633 |

---

### WARZONE-F10 — Campaign criteria (legacy) & trigger/event system (live)

**Legacy criteria schema** (`FILE_TAG_CAMPAIGN_CRITERIA`, comment-disabled inside dead code, `eech parser.c:948-1214`). Repeated `CRITERIA <type>` blocks per force; per type sub-keywords:

| Criteria type | Sub-keywords (order) | Source |
|---|---|---|
| `BALANCE_OF_POWER` | `GOAL <int>` `RESULT <result>` | eech parser.c:1001-1013 |
| `COMPLETED_TASKS`, `FAILED_TASKS` | `GOAL` `TYPE <task_sub_type>` `RESULT` | eech parser.c:1015-1032 |
| `DESTROYED_ALLIED_OBJECTS`, `DESTROYED_ENEMY_OBJECTS` | `GOAL` `TYPE <3d-object>` `RESULT` | eech parser.c:1034-1051 |
| `INEFFICIENT_ALLIED_KEYSITES`, `INEFFICIENT_ENEMY_KEYSITES` | `GOAL` `TYPE <keysite_sub_type>` `RESULT` | eech parser.c:1053-1070 |
| `SURRENDERED_SIDES` | `GOAL` `RESULT` | eech parser.c:1072-1084 |
| `SECTOR_REACHED` | `GOAL` `X_SECTOR <int>` `Z_SECTOR <int>` `RESULT` | eech parser.c:1086-1106 |
| `REACHED_WAYPOINTS` | `GOAL` `TYPE <waypoint_sub_type>` `RESULT` | eech parser.c:1108-1124 |
| `TIME_DURATION` | `DAYS` `HOURS` `MINUTES` `SECONDS` `RESULT` | eech parser.c:1126-1150 |
| `CAPTURED_SECTORS`, `LOST_SECTORS` | `GOAL` `RESULT` | eech parser.c:1152-1165 |
| `ENEMY_FIRED` | `GOAL` `RESULT` | eech parser.c:1167-1179 |

Optional per-criteria rewards: `EXPERIENCE_POINTS <int> VARIABLE <name>` and `RANK_POINTS <int> VARIABLE <name>` binding to player-log variables (`eech parser.c:1182-1208`); all fed to `add_force_campaign_critiera` (`eech parser.c:1210`), whose implementation is itself commented out (`eech force.c:123-168`).

**Live replacement**: `CREATE_TRIGGER <campaign_trigger_type> … EVENT <event_name>` (`eech parsgen.c:640-842`) → `add_campaign_trigger (type, value1..4, event_name, trigger)` (`eech parsgen.c:837`). Per-type keywords:

| Trigger | Keywords | Source |
|---|---|---|
| `BALANCE_OF_POWER` | `SIDE <int>` `GOAL <int>` `EVENT` | eech parsgen.c:666-688 |
| `TASK_COMPLETED, TASK_FAILED, OBJECT_DESTROYED, OBJECT_FIRED, OBJECT_TARGETED, OBJECT_LANDED, USER_LANDED, INEFFICIENT_KEYSITE, WAYPOINT_REACHED, SECTOR_WON, SECTOR_LOST, SECTOR_REACHED` | `EVENT` only | eech parsgen.c:690-713 |
| `TIME_DURATION` | `DAYS HOURS MINUTES SECONDS EVENT` (polled, trigger stored as NONE) | eech parsgen.c:715-747 |
| `VARIABLE_CONDITION` | `IF <variable> <operator> <value> EVENT` | eech parsgen.c:749-776 |
| `RANDOM` | `VALUE <int> EVENT` | eech parsgen.c:778-795 |
| `KEY_PRESS` | `KEY_CODE <dik> KEY_MODIFIER <mod> KEY_STATE <state> EVENT` | eech parsgen.c:797-826 |

Events are named script fragments (`CREATE_EVENT <name> … END_EVENT`) stored as file offsets and re-parsed when fired (`eech parsgen.c:586-638`).

---

### WARZONE-F11 — Force update tick (campaign completion assessment)

**Behaviour.** `update_server` for `ENTITY_TYPE_FORCE` is registered (`eech fc_updt.c:502-505`) but its entire body is one comment block (`eech fc_updt.c:86-495`) — the shipped tick does nothing. The (dead) design, kept as ground truth:

- Countdown `raw->sleep -= get_delta_time ()`; on expiry reset to `CAMPAIGN_COMPLETION_TIMER` = **5** (seconds) (`eech fc_updt.c:74`, `:125-134`).
- **Balance of power**: `force_percentage = Σ own current_hardware / Σ both sides' current_hardware` over all 8 categories, pushed to `FLOAT_TYPE_FORCE_PERCENTAGE` on change (`eech fc_updt.c:140-168`).
- Walk the criteria list. Semantics (header comment `eech fc_updt.c:66-67`): *all* SUCCESS criteria must be met to win; *any* FAIL criterion fails the campaign instantly.
  - `BALANCE_OF_POWER`: `count = force_percentage * 100`, met when `count >= goal` (`eech fc_updt.c:190-226`).
  - `CAPTURED_SECTORS` additionally publishes `objective_sectors_percentage = count/goal`, `INT_TYPE_OBJECTIVE_SECTORS_HELD/REQUIRED` (`eech fc_updt.c:227-249`), then falls through to the generic count check.
  - Generic (`COMPLETED_TASKS, DESTROYED_*_OBJECTS, ENEMY_FIRED, FAILED_TASKS, LOST_SECTORS, REACHED_WAYPOINTS, SECTOR_REACHED, SPECIAL_KILLS, SURRENDERED_SIDES`): met when `valid && count >= goal` (`eech fc_updt.c:250-296`).
  - `TIME_DURATION`: computes `time_percentage` (`this_time / elapsed_time_of_day` for SUCCESS criteria, `1 − …` for FAIL, `eech fc_updt.c:319-342`) and is met when elapsed days/hours/minutes/seconds all ≥ goal (`eech fc_updt.c:361-393`).
  - Any FAIL result stops the walk (`eech fc_updt.c:410-414`); SUCCESS demoted to NONE unless `success_achieved_count >= success_required_count` (`eech fc_updt.c:423-431`).
- On SUCCESS: add `experience_points`/`rank_points` to bound player-log variables; increment successful tours (`eech fc_updt.c:435-468`). On FAIL: increment failed tours (`eech fc_updt.c:469-478`). Either way: `setup_campaign_over_screen`, `start_game_exit (GAME_EXIT_KICKOUT, FALSE)`, push campaign-over screen (`eech fc_updt.c:489-493`).

**No funding/economy exists** anywhere in the force code — the only persistent per-side resources are the 8 reserve pools (F4) and keysite ammo/fuel supply levels (F7).

**Constants**

| Name | Value | Source |
|---|---|---|
| `CAMPAIGN_COMPLETION_TIMER` | 5 (s) | eech fc_updt.c:74 |
| balance-of-power percent scale | ×100 vs integer goal | eech fc_updt.c:193 |

---

### WARZONE-F12 — Force bookkeeping (live)

**Behaviour.** Live functions on the force entity: `add_to_force_info`/`remove_from_force_info` maintain `force_info_current_hardware` (and reserves, F4) keyed by the entity's `INT_TYPE_FORCE_INFO_CATAGORY` (`eech force.c:211-259`); `add_mobile_to_force_kills_stats`/`add_mobile_to_force_losses_stats` and `add_group_type_to_force_info`/`remove_group_type_from_force_info` maintain per-group-sub-type `kills/losses/group_count` (declared `eech force.h:165-173`); `get_force_space` exposes remaining capacity per category (`eech force.h:161`). `get_local_force_entity (side)` walks session force children (`eech force.c:89-118`).

---

### WARZONE-F13 — Sector-side map (population sides PSD)

**Behaviour** (`read_sector_side_file`, `eech popread.c:341-417`). Loads a PSD (`load_psd_file`); asserts 3 channels and dimensions exactly `(MAX_MAP_X_SECTOR+1) × (MAX_MAP_Z_SECTOR+1)` (`eech popread.c:370-372`). All sectors first reset to `ENTITY_SIDE_NEUTRAL` (`eech popread.c:423-449`). Then:
- Flat file (no layers) → whole image is the sides map (`eech popread.c:384-392`).
- Layered → layer named `BACKGROUND` (or empty name) = sides; layer named `IMPORTANCE` = importance map for `ENTITY_SIDE_RED_FORCE` (`eech popread.c:395-411`).

`process_population_forces` (`eech popread.c:455-514`): caches the raw layer (for `get_initial_sector_side`), then per pixel (rows flipped: image row y → sector row `MAX_MAP_Z_SECTOR − y`): red channel > 240 → `ENTITY_SIDE_RED_FORCE`; blue > 240 → `ENTITY_SIDE_BLUE_FORCE`; otherwise neutral **and `debug_fatal`** — neutral sectors are not allowed (`eech popread.c:487-509`). `get_initial_sector_side` re-derives side from the cached pixels with the same thresholds (`eech popread.c:557-584`).

`process_population_importance` (`eech popread.c:520-551`): stores red channel per sector (row-flipped). Consumers treat **zero** red as "important" (`important = value ? FALSE : TRUE`, `eech popread.c:1113-1121`).

**Constants**

| Name | Value | Source |
|---|---|---|
| side colour threshold | channel > 240 | eech popread.c:487, 494, 569, 574 |
| PSD dims | (MAX_MAP_X_SECTOR+1) × (MAX_MAP_Z_SECTOR+1), 3 channels | eech popread.c:370-372 |

---

### WARZONE-F14 — Population placement file: templates & city placement

**Behaviour.** `read_population_placement_file` (`eech popread.c:590-740`): computes `current_map_max_z = floor(terrain_3d_max_map_z/100)*100` (z-flip base, `eech popread.c:599-601`); validates airport route links for all 40 known airport/FARP objects (`eech popread.c:603-643`); then reads, in order, from one binary file: templates → city placements → airfield placements → SAM placements; finally `initialise_keysite_farp_enable` for both forces (`eech popread.c:721-723`) and `initialise_formation_database_table ()` (`eech popread.c:739`).

**Templates** (`read_population_templates`, `eech popread.c:746-912`) — binary format:
`int number_of_templates` (negative → version-2 file, absolute value used, `eech popread.c:754-762`); per template: `int number_of_objects`, `int type` (TEMPLATE_TYPE), `int valid` + length-prefixed name for approximation object, same for base object, and (v2 only) routes object (`eech popread.c:792-858`); then per object `float x, y, heading(deg→rad)` + length-prefixed 3D object name (`eech popread.c:867-903`).

**City placements** (`read_population_city_placements`, `eech popread.c:918-1470`) — `int number_of_instances`; per instance `int template_index, float x, float z` (`eech popread.c:973-975`). World z = `current_map_max_z − z` (`eech popread.c:1100`, `:1150`). Behaviour:
- KEY_* templates create keysites: `KEY_POWER → ENTITY_SUB_TYPE_KEYSITE_POWER_STATION`, `KEY_RADIO → RADIO_TRANSMITTER`, `KEY_INDUSTRY → FACTORY`, `KEY_PORT → PORT`, `KEY_MILITARY → MILITARY_BASE`, `KEY_OIL → OIL_REFINERY` (`eech popread.c:1081-1086`). Name = `"<translated short_name> <running total>"` (`eech popread.c:1095-1097`); side from initial sector side; created `IN_USE = TRUE`, ammo/fuel supply level 100.0, `INT_TYPE_KEYSITE_ID`, `INT_TYPE_OBJECT_INDEX = routes_object` (`eech popread.c:1123-1138`). (A v2 branch that would have created FACTORY/PORT keysites for INDUSTRY/PORTSE/PORTNW every 20th instance is commented out, `eech popread.c:993-1073`.)
- Non-key templates create an `ENTITY_TYPE_CITY` (sub-type `ENTITY_SUB_TYPE_FIXED_CITY`) parented to the sector (`eech popread.c:1196-1208`); ports take sea-level height, others terrain height (`eech popread.c:1156-1183`); base/approximation objects recorded on the city (ports insert base as a separate `ENTITY_TYPE_CITY_BUILDING`) (`eech popread.c:1221-1262`).
- Template objects become `CITY_BUILDING` (city) or SITE/SITE_UPDATABLE/SCENIC (keysite) via `insert_keysite_or_city_object` (`eech popread.c:4164-4241`): updatable 3D flag → `ENTITY_TYPE_SITE_UPDATABLE`; else importance > 0 → `ENTITY_TYPE_SITE`; else `ENTITY_TYPE_SCENIC` (`eech popread.c:4185-4233`). FARM template (or v2) objects find their own terrain height (`eech popread.c:1316-1328`).
- Scene-link objects on buildings: crane booms re-inserted as objects (`eech popread.c:1353-1365`); firing-point/marine scene links spawn 1-member `ENTITY_SUB_TYPE_GROUP_STATIC_INFANTRY` groups with formation components `LIGHT/MEDIUM/HEAVY_FIRING_POINT`, `INFANTRY_SAM_STANDING/KNEELING`, heading = link heading + building heading (`eech popread.c:1389-1458`).

---

### WARZONE-F15 — Population placement file: airfields, FARPs, carriers

**Behaviour** (`read_population_airfield_placements`, `eech popread.c:1476-2142`). `int number_of_instances`; per instance `float x, z` (z flipped) + length-prefixed 3D object name (`eech popread.c:1546-1565`).
- Special case: `OBJECT_3D_AIRFIELD_FR_CUBA_TREEBLOCK` → terrain object only, no AI (`eech popread.c:1568-1594`).
- Keysite sub-type by object: the 15 `*_AIRPORT*` objects → `ENTITY_SUB_TYPE_KEYSITE_AIRBASE`; the 26 `*_FARP*` objects → `ENTITY_SUB_TYPE_KEYSITE_FARP`; default → AIRBASE (`eech popread.c:1598-1673`).
- Water check: if terrain class at (x,z) is WATER the object becomes a carrier — red sector → `OBJECT_3D_KIEV_CLASS`, blue → `OBJECT_3D_TARAWA`, neutral → `debug_fatal`; sub-type `ENTITY_SUB_TYPE_KEYSITE_ANCHORAGE` (`eech popread.c:1678-1748`).
- 3D instance placed at terrain height + 0.05 m (z-buffer fix, `eech popread.c:1754`); waypoint-route sub-object hidden (`eech popread.c:1770-1783`); inserted into terrain unless anchorage (`eech popread.c:1787-1795`).
- Naming: AIRBASE → nearest `POPULATION_TYPE_KEYSITE` entry of the population-name database within 5 km (`get_keysite_name`, `eech popread.c:4247-4325`), else `"<short_name> <airfield_count>"`; FARP → `"<short_name> <farp_count>"`; ANCHORAGE → fixed carrier-name tables (`eech popread.c:1870-1919`).
- Keysite entity: parent force from side, `INT_TYPE_OBJECT_INDEX`, `INT_TYPE_KEYSITE_ID`, ammo/fuel 100.0 (`eech popread.c:1953-1967`).
- Waypoint routes: for each movement class the airport 3D object's sub-objects are searched (`OBJECT_3D_SUB_OBJECT_{FIXED_WING|HELI|ROUTED_VEHICLE|SHIP|TRANSPORT|PERSON}_{LANDING|TAKEOFF|LANDING_HOLDING|TAKEOFF_HOLDING}_ROUTE`); when landing+takeoff both exist, `insert_airport_fixedwing_routes` / `insert_airport_helicopter_routes` / `insert_airport_general_takeoff_landing_routes` (+ holding routes) build `ENTITY_TYPE_LANDING` children and waypoint routes for landing sub-types FIXED_WING / HELICOPTER / GROUND / SEA / FIXED_WING_TRANSPORT / PEOPLE (`eech popread.c:1988-2099`). Route geometry is extracted by routegen (F17) from the sub-object mesh.
- Buildings: `insert_airfield_buildings` (`eech popread.c:3943-4158`) walks the object's scene links; FARP landing-mat colour swapped by side (blue gets `OBJECT_3D_FARP_MAT`, red `OBJECT_3D_FARP_MAT_GREY`, `eech popread.c:3994-3999`); objects with a regeneration type create an `ENTITY_TYPE_REGEN` parented to the keysite and to the closest TAXI/NAVIGATION/LANDED waypoint of the matching landing route (initial best range 10000000, `eech popread.c:4001-4087`), with the building as the regen's member; otherwise SITE_UPDATABLE / SITE (importance > 0) / SCENIC as in F14. Carriers destruct the temp 3D object instead (`eech popread.c:2105-2115`).
- `validate_keysite_landing_site_heights` per keysite (`eech popread.c:2130`).

**Constants**

| Name | Value | Source |
|---|---|---|
| runway z-buffer lift | +0.05 m | eech popread.c:1754 |
| airbase naming radius | 5.0 km | eech popread.c:4284 |
| blue/red carrier name pools | 14 / 17 names | eech popread.c:287-326 |
| keysite initial supplies | ammo 100.0, fuel 100.0 | eech popread.c:1962-1963 (also 1057-1058, 1132-1133) |

---

### WARZONE-F16 — Population placement file: AAA/SAM sites

**Behaviour** (`read_population_sam_placements`, `eech popread.c:2148-2212`). `int number_of_instances`; per instance `float x, z` (z flipped, terrain height). Side from initial sector side. Always formation `FORMATION_COMPONENT_LIGHT_SAM_AAA_GROUP`, group `ENTITY_SUB_TYPE_GROUP_ANTI_AIRCRAFT`, member count = `max (0, component_count − 1)`, created keysite-less and local-only (`create_faction_members (NULL, …, FALSE, TRUE)`) (`eech popread.c:2200-2210`).

---

### WARZONE-F17 — Routegen: waypoint-route tree extraction from 3D objects

**Behaviour** (`parse_waypoint_routes_from_object`, `eech routegen.c:190-771`). Airfield taxi/landing routes are authored as a wireframe 3D sub-object; this converts it to an ordered multi-lane waypoint table:

1. Every mesh point becomes a `waypoint_node`; positions de-quantised from int16 by `max(|bbox min|,|bbox max|) / 32767` per axis (`eech routegen.c:225-273`). ASSERT `number_of_points < 768` (`eech routegen.c:223`).
2. Each 2-point face (line segment) increments both endpoints' `references`; surface colour encodes semantics — pure black surface (r=g=b=0) marks `possible_start` endpoints; pure green (0,255,0) marks `primary` route segments (`eech routegen.c:287-347`).
3. Start nodes: `possible_start && references == 1` → tree roots (depth 0, one tree per start, max 24) (`eech routegen.c:355-378`).
4. Tree growth: iterative passes over all segments — first only primary→primary expansion (from an in-route primary/start node to an out-of-route primary node), then all remaining nodes; each added child records parent/child pointers, `tree_depth = parent+1`, `tree_number = parent's` (`eech routegen.c:384-592`).
5. Primary flags propagate up parent chains; the primary start is swapped to `waypoint_starting_nodes[0]` (`eech routegen.c:598-646`).
6. `node_index` (lane index): main chain of each tree gets index = tree number (`eech routegen.c:652-667`); other nodes: single-parent → `hierarchy_width × child_index + parent->node_index`, multi-parent → lowest parent index (`set_node_indices`, `eech routegen.c:828-923`).
7. Optional slot matching (`match_end_slots`, `eech routegen.c:929-1022`): given N landing-slot positions, end nodes at max depth are swapped (via common ancestor child-pointer swap + reindex, `swap_waypoint_nodes` `eech routegen.c:1061-1233`) until end node k lies within **3.0 m** of slot k (`node_within_range`, `eech routegen.c:1028-1055`).
8. Output: `route_waypoint_positions[depth]` = number of lanes at that depth, absolute position of lane 0, per-lane offsets relative to lane 0 (`eech routegen.c:685-750`). `popread` walks this table to create the actual waypoint entities per depth (formation offsets = lane offsets), e.g. `WAYPOINT_ALTITUDE` macro (`eech popread.c:83`).

**Constants**

| Name | Value | Source |
|---|---|---|
| `MAX_WAYPOINT_NODES` / `LINKS` / `STARTS` | 768 / 24 / 24 | eech routegen.c:81-85 |
| point de-quantisation | axis_max / 32767 | eech routegen.c:257-259 |
| start-surface colour | RGB(0,0,0) | eech routegen.c:324-331 |
| primary-surface colour | RGB(0,255,0) | eech routegen.c:332-341 |
| slot match tolerance | 3.0 m | eech routegen.c:1045 |

---

### WARZONE-F18 — Road-node graph: files & loading

**Behaviour.** `load_route_data` (called during `CAMPAIGN_DATA`) reloads the road graph (`eech ai_route.c:166-171`); `read_road_route_data` tries base name `"ROADS"` then `"ROADDATA"` in `<data_path>\route\` (`eech ai_route.c:293-314`).

**`<name>.dat`** (`read_road_route_node_data`, `eech ai_route.c:331-538`): two 4-byte floats (map sizes, discarded, `eech ai_route.c:371-372`); `int total_number_of_road_nodes`; per node: `int node_id`, `int safe_radius` — **read but discarded and overridden to 28** (`eech ai_route.c:406-414`), `int number_of_links`, then per link `int node`, `int cost`; `breaks` initialised 0, `visited` initialised to `MAX_ROUTE_LENGTH` (100) (`eech ai_route.c:416-441`).

**`<name>.nde`** (`read_road_route_node_positions`, `eech ai_route.c:551-629`): `int count` (asserted equal to node count) then `count` raw `vec3d`s → `road_node_positions`. A disabled block would clamp node heights to terrain (`CHECK_ROUTE_NODE_HEIGHT` = 0, `eech ai_route.c:81`, `:597-626`).

**`<name>.wp`** (`read_road_route_node_link_positions`, `eech ai_route.c:644-781`): `int total_road_node_link_count`; per link: `int source`, `int destination`, `int path_type`, `int number_of_links` then that many raw `vec3d` intermediate positions. Loader prepends the source node position and appends the destination node position (array grows by 2, `eech ai_route.c:718-735`); every point x/z bounded to `[0, MAX_MAP_X/Z]` (`eech ai_route.c:741-746`). Sets `road_nodes_loaded = TRUE` (`eech ai_route.c:778`).

There is **no capacity or speed field** in the road data: `cost` (int, per directed link entry in `.dat`) is the only weight, and `path_type` is carried but not interpreted in ai_route.c. `safe_radius` (deployment space) is a constant 28 in this build.

**Constants**

| Name | Value | Source |
|---|---|---|
| `safe_radius` override | 28 (m) | eech ai_route.c:414 |
| `visited` reset value | MAX_ROUTE_LENGTH = 100 | eech ai_route.c:419, ai_route.h:69 |
| max bridges (breaks) per link | 32 | eech ai_route.c:1082-1086 |
| node id bit width | 14 bits (≤ 16383 nodes) | eech ai_route.h:105, :119 |
| number_of_links bit width | 7 bits (≤ 127 links/node) | eech ai_route.h:121 |
| file base names | `ROADS` then `ROADDATA` | eech ai_route.c:302-313 |

**Rebuild recipe for a DCS map**: nodes = `{id, position (x,y,z), safe_radius, links[]}`; link = `{target node id, cost (int; the debug print reads it as km, eech ai_route.c:1017), breaks (destroyed-bridge count)}`; separately, per unordered node pair `(source<destination)` one polyline `{path_type, positions[] including both endpoints}` for vehicles to follow between the nodes.

---

### WARZONE-F19 — Road-node graph: queries & routing

**Behaviour.**
- `get_closest_road_node (pos, error)` — linear scan of all nodes **with links**, approximate 2D range, early-out when ≤ `error` metres (`eech ai_misc.c:480-528`). Variant `get_closest_side_road_node` exists but its side filter (`side_aware`) is commented out (`eech ai_misc.c:534-577`). Callers: frontline spread (`eech faction.c:1191`, error 5.0), task route generation (`eech croute.c:639`, 5.0), landing creation (`eech ld_creat.c:181`, 10.0).
- `get_road_link_data (n1, n2)` — normalises order (n1 < n2), reverse-linear search of the link-polyline table for exact `(source, destination)` match; same-node → NULL (`eech ai_route.c:824-892`).
- `get_road_sub_route (n1, n2, &count, start_route)` — same lookup but can resume searching after a given record (multiple polylines may exist per pair); returns polyline + `number_of_links` count (`eech ai_route.c:898-1063`). Consumers: routed-vehicle movement (`eech mb_msgs.c:1746`, `eech rv_pack.c:281`, `eech en_comms.c:4874`).
- Bridge integration: `set_road_link_breaks (n1, n2, count)` sets `breaks` symmetrically on both directed entries (asserts symmetric links exist, `eech ai_route.c:1069-1117`); `get_road_link_breaks` returns the symmetric value or −1 (`eech ai_route.c:1123-1162`). Bridges increment/decrement this on destruction/repair (`eech bridge.c:932-936`, `eech br_msgs.c:131-135`, `eech br_pack.c:308-312`). A link with `breaks > 0` is impassable to the AI (checked before advance, `eech highlevl.c:516`, `eech gp_msgs.c:454`, `:627`, `:769`).
- **Movement over the graph is single-hop, not path-searched**: `create_group_ground_advance_route` picks the best *adjacent* node — for each link of the group's current `route_node`, candidate must not be `side_occupying` by own side, must have `breaks == 0`, must be inside the adjusted map area; rating `2.0 × IMAP_BASE_DISTANCE(enemy side)` (closer to enemy base = warmer); the best-rated group advances one node per decision, one group per side per pass (`eech highlevl.c:505-563`). Retreat logic similarly scans links for `breaks == 0` (`eech gp_msgs.c:627`, `:788`).
- The exported search scratch (`best_cost`, `best_recurse_level`, `current_route[100]`, `best_route[100]`, per-node `visited`) is initialised (`eech ai_route.c:129-131`, `clear_road_route_data` `eech ai_route.c:787-814`, called each AI frame from `eech ai.c:229`) but **no recursive path-search function exists in the live tree** — vestigial. A commented-out `initialise_road_safe_radius` would have computed per-node safe radius by growing a circle over ground-vehicle-suitable terrain up to `MAX_SAFE_RADIUS_CHECK` = 50 km (`eech ai_route.c:1168-1233`).

**Constants**

| Name | Value | Source |
|---|---|---|
| advance rating weight | 2.0 × enemy-base-distance imap | eech highlevl.c:532 |
| group candidate rating | 1.0×(1−enemy dist) + 1.0×(own dist) | eech highlevl.c:457-460 |
| groups advanced per pass | 1 per side | eech highlevl.c:557-562 |
| `MAX_SAFE_RADIUS_CHECK` (dead) | 50 km | eech ai_route.c:1168 |

---

### WARZONE-F20 — Briefing text database

**Behaviour** (`initialise_briefing_parser`, `eech briefing.c:209-717`). Loads `..\common\data\brief_<lang>.dat` by current language (`eech briefing.c:241-245`). Tag schema:

| Tag | Content |
|---|---|
| `FILE_TAG_UNICODE` | marks file as UTF-8 (else strings pass through `string_to_utf8`) (`eech briefing.c:264-269`) |
| `FILE_TAG_TYPE <task_sub_type>` | begins a task block: first section repeated `TEXT1`/`TEXT2`/`TEXT3` paragraphs until `END` (briefing sentence pools, max 30 each, `eech briefing.c:271-403`); second section repeated `SUCCESS`/`PARTIAL`/`FAILURE` paragraphs until `END` (debriefing pools, `eech briefing.c:409-514`) |
| `FILE_TAG_MEDAL {TYPE <medal>}* TEXT1* END` | medal texts; applies to a bitmask of medal types (`eech briefing.c:519-592`) |
| `FILE_TAG_PROMOTION TEXT1* END` | promotion texts (sub_type 0 — one pool for all ranks, `eech briefing.c:594-646`, comment `eech briefing.c:1495`) |
| `FILE_TAG_OBJECTIVES TYPE <keysite_sub_type> TEXT1* END` | per-keysite-type campaign objective texts (`eech briefing.c:648-705`) |
| `FILE_TAG_END` | end of file (`eech briefing.c:708-714`) |

---

### WARZONE-F21 — Briefing/debriefing generation & token substitution

**Behaviour.**
- `get_briefing_text (task, t1, t2, t3)` (`eech briefing.c:1275-1345`): deterministic pseudo-random selection keyed on the task's entity index — `text1_choice = index % text1_count`, with a running `remainder = index / count` folded into the choices for text2/text3 (`eech briefing.c:1302-1330`); each chosen paragraph passes through substitution. Missing pool → warning + FALSE.
- Substitution (`build_substitution_info`, `eech briefing.c:826-906`): literal copy except where one of 7 tokens occurs (first occurrence per token, found via `strstr`): `GROUP`, `KEYSITE`, `MEDAL`, `POSITION`, `RANK`, `SECTOR`, `TARGET_TYPE` (table `eech briefing.c:158-203`). Token expansions:
  - `POSITION` → `"<x> : <z>"` from task `VEC3D_TYPE_STOP_POSITION` (task) or entity position (`eech briefing.c:912-946`).
  - `SECTOR` → `"Sector [xxx:zzz]"` (translated; Polish drops the word) (`eech briefing.c:952-1001`).
  - `KEYSITE` → keysite name via task's `LIST_TYPE_TASK_DEPENDENT` parent (non-keysite parent → `debug_fatal`) (`eech briefing.c:1007-1064`).
  - `GROUP` → `"<group division name>, <company division name>"` (`eech briefing.c:1091-1131`).
  - `TARGET_TYPE` → target's `STRING_TYPE_FULL_NAME` (`eech briefing.c:1137-1164`).
  - `MEDAL` → US or CIS medal name by task side (`eech briefing.c:1170-1187`); `RANK` → translated rank name (`eech briefing.c:1193-1199`).
- `get_debriefing_text (task, &debrief, &ff_debrief)` (`eech briefing.c:1351-1445`): selects from success/partial/failure pool by `INT_TYPE_TASK_COMPLETED` (`text_choice = index % pool_count`); if `get_task_friendly_fire_incidents (task)` an additional friendly-fire debrief is drawn from the pools of `ENTITY_SUB_TYPE_TASK_NOTHING` (`eech briefing.c:1371-1376`); debrief of an incomplete task → `debug_fatal` (`eech briefing.c:1432-1438`).
- `get_medal_briefing_text` / `get_promotion_briefing_text` / `get_objective_briefing_text` (`eech briefing.c:1451-1551`): look up the extra-briefing list (medal via bitmask `sub_type & (1 << medal)`, `eech briefing.c:1241-1251`), choose `index % text_count`, substitute.

**Constants**

| Name | Value | Source |
|---|---|---|
| texts per pool | ≤ 30 | eech briefing.h:67 |
| substitution tokens | 7 (GROUP, KEYSITE, MEDAL, POSITION, RANK, SECTOR, TARGET_TYPE) | eech briefing.c:158-203 |
| choice function | entity_index % pool_count (+ remainder chaining) | eech briefing.c:1302-1330 |

---

## 4. Interactions

- **Parser → everything**: the campaign file drives faction creation (F3), reserves (F4 → regen `rg_updt.c`), task generation validity (F5 → `ai/taskgen`), regen cadence (F6), keysite supplies (F7 → keysite supply model), initial OOB (F7a-d), scripted tasks (F8 → task/guide system), frontline placement (F9 → road graph + imap + sectors), triggers/events (F10 → runtime campaign scripting), and loads the road graph (F2 step 6) and population data (F13-F16).
- **Population → sectors/imap**: sector `INT_TYPE_SIDE` seeds the entire sector-ownership game state; keysite creation feeds keysite lists that supply, regen, task generation, and win logic all consume. `population_importances` gates "important" flags on keysites.
- **Road graph → ground war**: frontline placement (F9), high-level advance/retreat decisions (F19; ratings from `imaps`), routed-vehicle waypoint following (`mb_msgs.c`, `rv_pack.c`, `en_comms.c`), and bridges (breaks make links impassable). `safe_radius` sizes deployed formations (F7d, F9).
- **Routegen → landing system**: extracted route trees become `ENTITY_TYPE_LANDING` waypoint routes; regens attach to their closest waypoints; landing locks/slots (F7a-c) operate on the same routes.
- **Force struct → UI/win**: `force_percentage`, sector percentages and criteria were consumed by the (dead) campaign-over flow and the in-game campaign UI (`ui_menu/ingame/campaign/*`); kills/losses/group counts feed logs and debriefs.
- **Briefing ← task system**: briefing draws task type, dependents (keysite/group/target), stop position, completion state and friendly-fire counts from task entities; medal/rank flows come from the player-log/promotion system.

## 5. Port mapping

Context (per port summary): the DCS port has no warzone parser, no road network, no population model, no briefing system, and no factions tick; the installations module procedurally creates depot/fuel/radar statics; supply is finite per-side role pools seeded in code; win_condition uses 3 hardcoded criteria.

| Feature | Status | Note |
|---|---|---|
| WARZONE-F1 master tag schema | NOT PORTED | No campaign-file parser; campaign setup is hardcoded in Lua modules. |
| WARZONE-F2 CAMPAIGN_DATA (map/files/factions/routes) | PROXY | Map geometry comes from the DCS terrain; installations module procedurally creates keysite-like statics instead of side/population/route files. |
| WARZONE-F2a object population sub-file | NOT PORTED | Dead in EECH too; DCS map provides scenery. |
| WARZONE-F3 faction declaration | PROXY | Two hardcoded sides replace FORCE entities; no colour/attitude fields. |
| WARZONE-F4 hardware reserves | PROXY | Supply is finite per-side role pools seeded in code — same concept, but pools are role-based and not fed from a warzone file; decrement-on-spawn semantics should be verified against `add_to_force_info` (decrement only when in play, not during initial OOB creation). |
| WARZONE-F5 task generation config | NOT PORTED | No per-task valid/frequency toggles from data; task mix is code-defined. |
| WARZONE-F6 regen frequency | UNKNOWN | Port has respawn/regen logic in spawner code; whether a per-side frequency knob exists is not established here. |
| WARZONE-F7 keysite selection & initial OOB (CREATE_MEMBERS/GROUP) | PROXY | Installations module creates depot/fuel/radar statics procedurally; landed-member placement with landing-slot locks is NOT PORTED. |
| WARZONE-F8 scripted tasks (CREATE_TASK) | NOT PORTED | No campaign-script task injection. |
| WARZONE-F9 frontline force placement | NOT PORTED | Requires the road graph and sector sides; port has neither. |
| WARZONE-F10 campaign criteria / triggers & events | PROXY | win_condition uses 3 hardcoded criteria; no data-driven criteria, no script events/triggers, no experience/rank rewards. |
| WARZONE-F11 force update tick | NOT PORTED | Dead in EECH as well; port's win_condition is the closest analogue (its own cadence, 3 criteria). |
| WARZONE-F12 force bookkeeping | PARTIAL | Per-side pools imply some current/reserve counting; per-group-type kills/losses/group_count tables UNKNOWN. |
| WARZONE-F13 sector side PSD | NOT PORTED | No sector ownership bitmap; port has no sector model per summary. |
| WARZONE-F14 city/keysite template placement | PROXY | Installations module procedurally creates statics; no template file, no city entities, no importance layer. |
| WARZONE-F15 airfield/FARP/carrier placement | PROXY | DCS airbases/FARPs replace object-based keysites; carrier keysites, landing-route extraction and regen-building attachment NOT PORTED. |
| WARZONE-F16 AAA/SAM placement | UNKNOWN | Port spawns air defence via its own spawner; equivalence to sector-side-driven placement not established. |
| WARZONE-F17 routegen route-tree extraction | NOT PORTED | DCS provides taxi/landing logic natively; nothing to extract. |
| WARZONE-F18 road graph files/loading | NOT PORTED | No road network in the port. |
| WARZONE-F19 road graph queries/advance decisions | NOT PORTED | No road network; single-hop advance/retreat model absent. |
| WARZONE-F20 briefing database | NOT PORTED | No briefing system. |
| WARZONE-F21 briefing generation/substitution | NOT PORTED | No briefing system. |

## 6. Open questions

1. **Which parser is authoritative for the port?** `parser.c` is fully dead; `parsgen.c` is live and differs materially (TASK_GENERATION loses duration/frequency/urgency; REGEN_FREQUENCY becomes absolute; FRONTLINE_FORCES FARP seeding pattern changes; criteria → triggers/events). This spec captures both; a port should follow `parsgen.c` semantics.
2. **`CAMPAIGN_CRITERIA_*` enum is missing from the tree** — dead code in `parser.c`/`fc_updt.c` references an enum and `campaign_criteria_names[]` that no longer exist. The original criteria semantics can only be inferred from the dead tick (F11); exact enum ordering/values are unrecoverable from this source.
3. **Road-graph path search**: `best_route`/`current_route`/`visited`/`best_cost` are declared and reset every AI frame (`eech ai.c:229`) but no search function uses them. Was a Dijkstra/DFS removed, or does the single-hop advance model (F19) fully replace it? Behaviourally the shipped game moves ground groups one adjacent node at a time.
4. **`link_data.cost` units**: read as raw int; the only interpretive hint is a debug format string printing it as `%f km` (`eech ai_route.c:1017`) with an int argument — likely metres or km depending on generator; not resolvable from this code alone.
5. **`path_type` in `.wp` records** is loaded but never read in `ai_route.c`; its meaning (road class? bridge flag?) is unknown from these files.
6. **`safe_radius` override to 28** (`eech ai_route.c:414`, comment "override - DL") discards authored per-node values; the dead `initialise_road_safe_radius` shows the intended terrain-scan derivation. Which behaviour is "EECH-faithful" for a port is a judgement call — the shipped binary uses 28 everywhere.
7. **`FILE_TAG_END_CAMPAIGN`** (live parser) reads a result enum but the visible fragment does not act on it (`eech parsgen.c:344-355`); actual end-campaign side effects presumably live in code outside the read range (e.g. via events) — unverified.
8. **`regen_frequency` defaults** (value before any `REGEN_FREQUENCY` tag) are set elsewhere (`regen.h` declares the array; initialisation site not read) — default cadence unverified.
9. **`get_regen_frequency_difficulty_modifier`** scales the live regen sleep (`eech rg_updt.c:182`); its value table was not read.
10. **`start_time`/`stop_time` in CREATE_TASK** are parsed and discarded in both parsers — intended scheduling semantics unknown.
11. **Population placement file provenance**: the binary format (F14-F16) is produced by an external tool; only reader-visible structure is specced. Cited via reader functions per the data-driven rule.
