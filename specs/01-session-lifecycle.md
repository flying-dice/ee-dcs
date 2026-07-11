# EECH Spec 01 — Session Lifecycle, Time & Campaign Flow

Sources:
- `aphavoc/source/entity/special/session/` (session.h, session.c, ss_creat.c, ss_updt.c, ss_pack.c, ss_float.c, ss_int.c, ss_dstry.c, ss_msgs.c)
- `aphavoc/source/entity/special/update/` (up_update.c, up_update.h, up_creat.c)
- `aphavoc/source/entity/special/group/gp_updt.c` (update-list membership example)
- `aphavoc/source/gameflow/gameflow.c`, `gameflow.h`
- `aphavoc/source/flight.c` (main flight/game loop)
- `aphavoc/source/update.c` (timed update-function scheduler)
- `aphavoc/source/ai/ai.c`, `ai/highlevl/highlevl.c` (campaign scheduler registration), `ai/highlevl/setup.c` (campaign objectives)
- `aphavoc/source/ai/faction/faction.c` (create_campaign), `ai/parser/parsgen.c` (campaign file parser, script triggers)
- `aphavoc/source/entity/special/force/fc_msgs.c`, `force.c` (campaign completion check, timer display)
- `aphavoc/source/ui_menu/ingame/campaign/` (campaign.c/h, ca_menu.c, ca_stat.c, ca_save.c)
- `aphavoc/source/ui_menu/session/uisession.c` (store_session), `ui_menu/sessparm/sparm_sc.c` (setup options)
- `aphavoc/source/misc/timeaccl.c/h`, `aphavoc/source/entity/system/en_comms/en_sessn.c` (pack/unpack session)
- `aphavoc/source/global.h`, `aphavoc/source/cmndline.c`, `modules/maths/constant.h`

## 1. Overview

EECH's campaign runs inside a single **session entity** — the root of the whole campaign entity tree (session → forces → keysites/groups → members → tasks). The session entity owns game time (start time + elapsed time, with a time-of-day acceleration multiplier), day-segment classification (dawn/day/dusk/night), the weather and wind models, population-area bounds, and campaign-level flags (complete, medal, cheats, realism options).

Three distinct update mechanisms drive the campaign:

1. **Per-frame entity update list** — the local-only *update entity* keeps a `LIST_TYPE_UPDATE` child list; every frame `update_client_server_entities()` walks it and calls each entity's overloaded update function. Entities insert/remove themselves dynamically (e.g. a group is only on the list while its sleep/assist timers are running).
2. **Timed update-function scheduler** — a linked list of `(function, sleep_time, last_update_timer)` records ticked once per frame; this is how all high-level campaign AI (task generation, imap normalisation, fog-of-war decay, sector census, campaign script triggers) gets its cadence (from 1 s to 30 min periods).
3. **The flight loop itself** — `flight()` in flight.c runs `count = time_acceleration` full entity-update iterations per rendered frame, so frame-level time acceleration accelerates the entire campaign, while `time_of_day_acceleration` accelerates only the clock.

Campaign start is a fall-through **game-initialisation state machine** (gameflow.c) which parses a `.chc` campaign script into the entity tree (`create_campaign`), picks 5 campaign-objective keysites per side (`setup_campaign`), then enters `flight()`. Campaign end is event-driven: keysite/helicopter destruction triggers a force-level objective check with three victory conditions. Persistence is a binary pack of the entire entity tree (`pack_session` with `PACK_MODE_SERVER_SESSION`) plus a small text script that points back at it; autosave is supported.

## 2. Data model

### struct SESSION — eech aphavoc/source/entity/special/session/session.h:67-153
| Field | Type | Notes |
|---|---|---|
| version_number | int | must be first; save-compat check |
| force_root, special_effect_root | list_root | children: forces, ambient sound effects |
| update_link | list_link | membership of update entity's LIST_TYPE_UPDATE list |
| start_time | float | time-of-day at campaign start (seconds) |
| elapsed_time | float | campaign elapsed seconds (advanced by dt × acceleration) |
| lightning_timer | float | countdown to next lightning strike |
| time_of_day_resync | float | MP resync accumulator |
| time_of_day_acceleration | float | clock multiplier (1.0 normal; 120 in demo) |
| fog_of_war_maximum_value | float | max FOW value, clamped 8×30 s .. 8 h (ss_creat.c:213) |
| weather_radius, weather_mode_transitional_period/status | float | local / global weather model state |
| weather_mode, target_weather_mode | weathermodes | current/target |
| weather_position, weather_velocity | vec3d | roving weather-circle centre |
| wind_effect_radius, wind_gusting_value, wind_minimum_speed, wind_maximum_speed | float | wind model |
| wind_direction_vector, wind_effect_position, wind_effect_velocity | vec3d | wind model |
| day_segment_type | day_segment_types | DAWN/DAY/DUSK/NIGHT |
| population_x_min/x_max/z_min/z_max | float | active population rectangle (reduced games / skirmish) |
| campaign_medal | bitfield | medal awarded on victory |
| campaign_requires_apache_havoc | bitfield | content gate flag |
| auto_assign_gunship | bitfield | from campaign file |
| session_complete | bitfield | holds a campaign_completed_types value |
| infinite_fuel, infinite_weapons, suppress_ai_fire, invulnerable_from_collisions, invulnerable_from_weapons, cheats_enabled | bitfields | realism/cheat flags |
| skip_night_time | bitfield | demo night skip |
| weather_increasing, wind_increasing, local_weather_model | bitfields | weather model state |

### struct UPDATE — eech aphavoc/source/entity/special/update/up_update.h:67-73
Single `list_root update_root` (the per-frame update list). Update entity is **local only** and must be created before any client/server entities so indices match across machines (up_creat.c:78-90).

### Timed update-function record — eech aphavoc/source/update.c:81-215
`update_function_data_type { function, sleep_time, last_update_timer, next }`; `add_update_function(fn, sleep_time, offset_time)` (update.c:155), `update_update_functions()` decrements `last_update_timer` by delta time and fires + reloads when ≤ 0 (update.c:281-310).

### Enums
| Enum | Values | Source |
|---|---|---|
| GAME_FLOW_TYPES | UNKNOWN, INSTANT_ACTION, COMBAT_MISSIONS | eech aphavoc/source/gameflow/gameflow.h:67-73 |
| GAME_INITIALISATION_PHASES | NONE, GAME_TYPE, SCENARIO, SETUP, GUNSHIP_TYPE, TRANSFERRING | eech aphavoc/source/gameflow/gameflow.h:81-91 |
| GAME_TYPES | INVALID, FREE_FLIGHT, CAMPAIGN, SKIRMISH, DEMO | eech aphavoc/source/global.h:99-107 |
| SESSION_TIME_OF_DAY_SETTINGS | INVALID, RANDOM, DAWN, MIDDAY, AFTERNOON, DUSK, MIDNIGHT | eech aphavoc/source/global.h:311-321 |
| SESSION_WEATHER_SETTINGS | INVALID, RANDOM, GOOD, FAIR, POOR | eech aphavoc/source/global.h:329-337 |
| SESSION_SEASON_SETTINGS | INVALID, DEFAULT, SUMMER, WINTER, DESERT | eech aphavoc/source/global.h:345-353 |
| DAY_SEGMENT_TYPES | DAWN, DAY, DUSK, NIGHT | eech aphavoc/source/entity/system/en_types/en_day.h:67-74 |
| CAMPAIGN_PAGES | BASE, BRIEFING, DEBRIEFING, GROUP, LOG, MAP, STATS, CHAT, SAVE, WEAPON_LOADING | eech aphavoc/source/ui_menu/ingame/campaign/campaign.h:76-90 |
| CAMPAIGN_COMPLETED_TYPES | FALSE, OBJECTIVES, VALID_GUNSHIPS | eech aphavoc/source/ui_menu/ingame/campaign/campaign.h:98-105 |
| CAMPAIGN_TRIGGER | NONE, BALANCE_OF_POWER, TASK_COMPLETED, TASK_FAILED, OBJECT_DESTROYED, OBJECT_FIRED, OBJECT_TARGETED, OBJECT_LANDED, INEFFICIENT_KEYSITE, WAYPOINT_REACHED, SECTOR_WON, SECTOR_LOST, SECTOR_REACHED, TIME_DURATION, VARIABLE_CONDITION, RANDOM, USER_LANDED, KEY_PRESS | eech aphavoc/source/entity/system/en_types/en_force.h:206-229 |

### Pack modes relevant to session
`PACK_MODE_SERVER_SESSION` (save/load full campaign), `PACK_MODE_CLIENT_SESSION` (client join transfer), `PACK_MODE_BROWSE_SESSION` (session browse), `PACK_MODE_UPDATE_ENTITY` (periodic MP resync) — dispatch in eech aphavoc/source/entity/special/session/ss_pack.c:79-224.

### Time units
`ONE_SECOND = 1`, `ONE_MINUTE = 60`, `ONE_HOUR = 3600`, `ONE_DAY = 86400` (seconds) — eech modules/maths/constant.h:161-169. All campaign clocks are floats in seconds.

## 3. Features

### SESSION-F1 — Session entity creation & defaults
The session entity is created server-side while parsing the campaign file's `CAMPAIGN_DATA` map block, immediately after the world map/sector grid and factions exist (`create_local_entity(ENTITY_TYPE_SESSION, …)` then `set_session_random_weather_mode`) — eech aphavoc/source/ai/parser/parsgen.c:1193-1206. Exactly one session may exist (`ASSERT (!get_session_entity ())`, ss_creat.c:105). It is inserted into the update entity's `LIST_TYPE_UPDATE` child list **immediately after the camera entity** so it updates right after the camera each frame (eech aphavoc/source/entity/special/session/ss_creat.c:221-229).

Creation defaults (eech aphavoc/source/entity/special/session/ss_creat.c:131-191):

| Constant | Value | Source |
|---|---|---|
| session_complete | FALSE | ss_creat.c:135 |
| cheats_enabled | FALSE | ss_creat.c:137 |
| start_time | get_session_random_start_time_of_day() | ss_creat.c:139 |
| time_of_day_acceleration | 1.0 | ss_creat.c:141 |
| local_weather_model | TRUE | ss_creat.c:143 |
| weather_mode / target | WEATHERMODE_DRY | ss_creat.c:145-147 |
| weather_radius / wind_effect_radius | 40 km | ss_creat.c:149-151 |
| weather_mode_transitional_period | 60.0 s | ss_creat.c:153 |
| weather_position | map centre | ss_creat.c:157-159 |
| weather_velocity | (300 kt, 0, −100 kt) | ss_creat.c:161-163 |
| wind_effect_velocity | (240 kt, 0, 350 kt) | ss_creat.c:169-171 |
| lightning_timer | ONE_MINUTE | ss_creat.c:173 |
| wind min/max speed | 5 kt / 25 kt (DEFAULT_MIN/MAX_WIND_SPEED) | session.h:185-186, ss_creat.c:175-176 |
| population bounds | whole map | ss_creat.c:186-189 |
| fog_of_war_maximum_value | command_line value, then bound [8×FOG_OF_WAR_DECAY_RATE, 8×ONE_HOUR] = [240 s, 8 h] | ss_creat.c:191, 213; FOG_OF_WAR_DECAY_RATE = 30.0 eech aphavoc/source/ai/highlevl/highlevl.h:67; default = DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE = 4 h, highlevl.h:69, cmndline.c:313 |

After creation, ambient sound-effect child entities are attached (`attach_session_sound_effects`, eech aphavoc/source/ai/faction/faction.c:150, session.c:659-882).

### SESSION-F2 — Update entity & per-frame entity update scheduling
- The update entity is local-only, created before any client/server entity (eech aphavoc/source/entity/special/update/up_creat.c:78-90).
- `update_client_server_entities()` (called every flight-loop iteration, flight.c:368) walks the update entity's `LIST_TYPE_UPDATE` child list; for each child it caches the successor in `update_succ` **before** calling the entity's update (so an entity may delete itself from the list mid-walk), calls `update_client_server_entity(en)` (per-type function table `fn_update_client_server_entity[type][comms_model]`, eech aphavoc/source/entity/system/en_funcs/en_updt.h:69), and marks it in the `updated_entities` bit array — eech aphavoc/source/entity/special/update/up_update.c:112-200.
- **Fixed-step subdivision**: when the frame rate is unlocked, the frame is split into `iterations = (int)(delta_time × frame_rate + 1)` sub-steps with `manual_delta_time = delta_time / iterations`; requested `frame_rate` is `command_line_entity_update_frame_rate` (default **2**, eech aphavoc/source/cmndline.c:110), asserted 1..100 — eech aphavoc/source/entity/special/update/up_update.c:206-232.
- **Dynamic membership**: campaign entities join the list only while they need per-frame time. Example: a group is on the update list only while `sleep > 0` or `assist_timer > 0`; its server update decrements both by delta time and removes itself from `LIST_TYPE_UPDATE` when both hit zero — eech aphavoc/source/entity/special/group/gp_updt.c:79-108. (Keysites, regen queues etc. use the same `FLOAT_TYPE_SLEEP` pattern; see their own specs.)
- Session's own per-frame update: server = time-of-day, resync, transitional weather, session sound effects (ss_updt.c:921-930); client = same minus resync (ss_updt.c:936-943).

### SESSION-F3 — Timed update-function scheduler (campaign cadence table)
`update_update_functions()` is called once per flight-loop iteration (flight.c:372, and during server pause when `command_line_pause_server`, flight.c:347). Each record fires when its countdown expires and reloads to `sleep_time` (eech aphavoc/source/update.c:281-310). High-level campaign functions are registered server-only in `start_high_level_ai()` via `add_high_level_ai_function(fn, frequency, start_time)`, which phase-aligns the first firing to campaign elapsed time: `offset = fmod(start_time − elapsed_time, frequency)` (+frequency until ≥ 0); asserts frequency divides 24 h exactly — eech aphavoc/source/ai/highlevl/highlevl.c:346-369.

Registration table (eech aphavoc/source/ai/highlevl/highlevl.c:181-287). All values seconds:

| Function | CAMPAIGN freq / offset | SKIRMISH freq / offset |
|---|---|---|
| create_cas_tasks | 15 min / 0 | 6 min / 0 |
| create_troop_patrol_tasks | 5 min / 5 | 10 min / 5 |
| create_advance_and_retreat_tasks | 12 min / 12 | 15 min / 12 |
| create_keysite_strike_tasks | 7.5 min / 15 | 10 min / 15 |
| create_artillery_strike_tasks | 15 min / 45 | 12 min / 8 |
| create_troop_insertion_tasks | 2 min / 60 | 2 min / 60 |
| create_oca_sweep_tasks | 30 min / 90 | 20 min / 240 |
| create_helicopter_transfer_tasks | 7.5 min / 120 | 10 min / 180 |
| create_fixed_wing_transfer_tasks | 15 min / 150 | 15 min / 34 |
| create_sead_tasks | 12 min / 180 | 10 min / 2 |
| create_bai_tasks | 20 min / 300 | 10 min / 90 |
| create_oca_strike_tasks | 30 min / 390 | 30 min / 300 |
| normalise_importance_imaps | 2 min / 20 | same |
| normalise_base_distance_imaps | 2 min / 40 | same |
| normalise_air_defence_imaps | 2 min / 60 | same |
| normalise_surface_defence_imaps | 2 min / 80 | same |
| update_client_server_sector_fog_of_war | FOG_OF_WAR_DECAY_RATE = 30 s / 8 | same |
| update_client_server_sector_side_count | 1 min / 15 | same |
| update_campaign_triggers | 1 s / 0 | same |

`stop_high_level_ai()` removes them all and deinitialises imaps (highlevl.c:293-340). `start_ai_system()`/`stop_ai_system()` are just wrappers (eech aphavoc/source/ai/ai.c:124-136), invoked from `flight()` (flight.c:214, 572).

### SESSION-F4 — Game time, day number and day segments
- Advance (every session update): `elapsed_time += delta_time × time_of_day_acceleration` — eech aphavoc/source/entity/special/session/ss_updt.c:95.
- Time of day: `time_of_day = start_time + elapsed_time`, reduced mod ONE_DAY; the reduction count is the day number; `INT_TYPE_DAY` getter returns count + 1 (1-based) — eech aphavoc/source/entity/special/session/session.c:136-171, ss_int.c:351-358.
- Day segments (eech aphavoc/source/entity/special/session/session.c:177-204): tod < 6 h → NIGHT; < 8 h → DAWN; < 18 h → DAY; < 20 h → DUSK; else NIGHT. Segment start times: DAWN = 6 h, DAY = 8 h, DUSK = 18 h, NIGHT = 20 h (session.c:210-244). `day_segment_type` is recomputed every session update (ss_updt.c:119) and also when `FLOAT_TYPE_START_TIME` is set (ss_float.c:151-158).
- Random start time of day: one of 6 base times {0.5, 5.5, 9.0, 12.0, 15.0, 17.5} h ± up to 15 min (`floor(sfrand1() × 15 min)`), wrapped into [0, 24 h) — eech aphavoc/source/entity/special/session/session.c:250-289.
- Preset start times: DAWN 05:45, MIDDAY 11:50, AFTERNOON 15:20, DUSK 18:00, MIDNIGHT 23:45 — eech aphavoc/source/entity/special/session/session.c:295-311.
- Host setup applies a weather setting and time-of-day setting (RANDOM or preset) to the session at campaign/skirmish/free-flight start by setting `FLOAT_TYPE_START_TIME` — eech aphavoc/source/ui_menu/sessparm/sparm_sc.c:1548-1666. On restore, setup options are re-applied only for FREE_FLIGHT; campaign restores keep saved values (sparm_sc.c:1672-1728).
- **Note**: no campaign-logic consumer of NIGHT was found in `ai/` (task generation does not check day segment); day segment drives rendering/cockpit lighting only. (Searched `ai/` for day-segment usage — zero hits.)

### SESSION-F5 — Demo night-skip & clock acceleration
- `skip_night_time`: if tod passes NIGHT start (20 h), jump elapsed_time forward by `(ONE_DAY − tod) + DAWN start (6 h)`; if tod < 6 h, jump to 6 h — eech aphavoc/source/entity/special/session/ss_updt.c:103-117.
- DEMO game type sets `time_of_day_acceleration = 60 × 2.0 = 120×` and `skip_night_time = TRUE` on flight entry, restored to 1.0 / FALSE on exit — eech aphavoc/source/flight.c:199-201, 560-562. Debug events can set the clock to 10×/30×/60× ONE_MINUTE rates (eech aphavoc/source/events/ev_debug.c:938-989). The clock multiplier affects **only** elapsed_time (and hence day/night); it does not speed up entity simulation.

### SESSION-F6 — Frame-level time acceleration (whole-campaign fast-forward)
- `time_acceleration` (int): PAUSE = 0 (eech aphavoc/source/misc/timeaccl.h:67), min = 1, max = 1 in release builds / 10 in DEBUG (timeaccl.c:79-93); effective max = `max(max_time_acceleration, command_line_max_time_acceleration)` with command-line default **4** (timeaccl.c:109-112, cmndline.c:123).
- Server-only, and refused entirely when a multiplayer connection exists (timeaccl.c:232-250). Pause toggling pauses/continues the sound system (timeaccl.c:252-259).
- The flight loop runs `count = get_time_acceleration()` full iterations of {receive comms, update_client_server_entities, update_update_functions, update view/timers} per rendered frame; count 0 = paused (only camera updates, plus comms if `command_line_pause_server`) — eech aphavoc/source/flight.c:336-380. Because the scheduler (F3) is inside this loop, frame-level acceleration accelerates task generation, fog of war, triggers — everything.
- `flight()` initialises acceleration to min (1) on entry (flight.c:226); `game_update_time = TIME_1_SECOND / command_line_max_game_update_rate`, default rate 15 (flight.c:224, cmndline.c:143).

### SESSION-F7 — Multiplayer session resync
Server accumulates `time_of_day_resync += delta_time`; when it exceeds `SESSION_RESYNC_FREQUENCY = ONE_MINUTE` (eech aphavoc/source/entity/special/session/session.h:188) it transmits `ENTITY_COMMS_UPDATE` for the session and resets — eech aphavoc/source/entity/special/session/ss_updt.c:126-150. The `PACK_MODE_UPDATE_ENTITY` payload is: elapsed_time, lightning_timer, weather radius/position/velocity, wind radius/gusting/direction/position/velocity, weather_increasing, wind_increasing (ss_pack.c:96-135); clients apply it and mark the campaign timer display valid (ss_pack.c:160-211). Clients therefore get authoritative campaign time once per minute.

### SESSION-F8 — Weather model (session state)
Two modes, selected by `local_weather_model`:
- **Local (roving storm circle)** — default for campaigns (`set_session_random_weather_mode`, server-only): radius uniform in [MIN_WEATHER_RADIUS 5 km, MAX_WEATHER_RADIUS 100 km] (session.h:170-171), random start position on map, speed WEATHER_EFFECT_SPEED = 360 kt at random heading, random expanding/contracting flag — eech aphavoc/source/entity/special/session/session.c:538-589. Per-frame: circle moves and bounces off map edges; radius grows/shrinks at WEATHER_EXPANSION_RATE = 100 m/s (session.h:172) between min/max, flipping direction at the bounds — eech aphavoc/source/entity/special/session/ss_updt.c:303-419. Weather sampled at a point by range from centre: ≥ r → DRY; ≥ 0.666 r → DRY→LIGHT_RAIN transitional (ts = (r − range)/(0.333 r)); ≥ 0.333 r → LIGHT→HEAVY transitional; else HEAVY_RAIN; in WINTER season all rain becomes SNOW — eech aphavoc/source/entity/special/session/session.c:339-484. `get_simple_session_weather_at_point` picks current vs target at ts 0.5 (session.c:490-509).
- **Fixed/global** — `set_session_fixed_weather_mode` (server-only) clears local model and sets mode == target (session.c:515-532); the campaign file's `WEATHER_RAIN 0` tag forces fixed DRY (parsgen.c:1295-1316); global transitions advance `transitional_status += dt / transitional_period` (period default 60 s) — ss_updt.c:420-441.
- Host setup weather options: RANDOM (only if local model — i.e. campaign file didn't fix weather), GOOD = fixed DRY, FAIR = fixed LIGHT_RAIN, POOR = fixed HEAVY_RAIN (SNOW in winter) — eech aphavoc/source/ui_menu/sessparm/sparm_sc.c:1496-1541. DATA-DRIVEN: campaign file may set weather position/velocity/radius via `WEATHER` tag (reader: eech aphavoc/source/ai/faction/parser.c:778-819) and rain on/off via `WEATHER_RAIN` (reader: parsgen.c:1295).

### SESSION-F9 — Wind model & gusting
Same roving-circle pattern: radius in [MIN_WIND_RADIUS 8 km, MAX_WIND_RADIUS 128 km], expansion WIND_EXPANSION_RATE = 200 m/s, effect speed WIND_EFFECT_SPEED = 400 kt (session.h:176-180); position bounces off map edges; wind direction = normalised vector from map centre to wind-effect position — ss_updt.c:443-527. Wind speed at a point: min speed outside circle, linearly interpolated up to max at the centre (`r = (radius − range)/radius`), then modulated by a gust value: `wind_gusting_value += dt × WIND_GUST_FREQUENCY (0.1)` wrapping at 1.0 (session.h:182, ss_updt.c:484-489), mapped through a 6-point piecewise-linear table {0.25, −0.05, −0.25, 0.05, −0.01, 0.15} (session.c:99-110, 888-938) as a fractional speed modifier — eech aphavoc/source/entity/special/session/session.c:595-653.

### SESSION-F10 — Lightning timer
Runs only when the camera is inside bad weather (local model). Server decrements `lightning_timer`; at ≤ 0 it fires a strike and sets a new timer uniform in [LIGHTNING_EFFECT_MINIMUM_TIMER 20 s, LIGHTNING_EFFECT_MAXIMUM_TIMER 4 min] via a replicated float set; clients count their copy down and fire at 0, waiting for the server's next value — eech aphavoc/source/entity/special/session/ss_updt.c:156-297. (Strike visuals/sounds are presentation; the timer state is replicated and saved.)

### SESSION-F11 — Gameflow state machine (campaign start/end)
`game_initialisation_phase` starts at NONE; `initialise_game_initialisation_phases()` resets game type INVALID, gunship type/side neutral, then applies command-line overrides — eech aphavoc/source/gameflow/gameflow.c:115-137. `process_game_initialisation_phases()` is a **fall-through switch** (each phase falls into the next when its precondition is met) — gameflow.c:143-1012:

1. **NONE**: dedicated-server bootstrap — force COMMS_MODEL_SERVER; defaults GAME_TYPE_CAMPAIGN, GUNSHIP_TYPE_APACHE; synthesises a host session with data path `..\common\maps\map6`, directory `camp01`, filename `yemen.chc` when none given (gameflow.c:175-276).
2. **GAME_TYPE**: waits for a valid game type; then `set_game_status(GAME_STATUS_UNINITIALISED)`, opens the comms pack buffer (gameflow.c:283-330).
3. **SCENARIO**: server reads the campaign file header (TITLE, SHORT_TEXT briefing lines, IF/ENDIF against the player log, VERSION_NUMBER); a restore whose file `VERSION_NUMBER != get_global_version_number()` is rejected with "INVALID_SAVED_GAME" (gameflow.c:511-538). Clients join the DirectPlay session and request campaign data instead (gameflow.c:623-676).
4. **SETUP**: `GAME_STATUS_INITIALISING`; initialises callsign DB, message log, warzone bridge DB; server captures server-side option globals from command line (planner goto button, vector flight model, ground-radar-ignores-infantry, camcom, `session_campaign_map_update_interval` [default 120 s, eech aphavoc/source/cmndline.c:278], russian NVG, cloud puffs, packet size — gameflow.c:748-762), loads terrain and reinitialises the entity system; clients send CAMPAIGN_DATA_REQUEST (gameflow.c:699-844).
5. **GUNSHIP_TYPE**: once a side is chosen — HOST: `create_campaign` + `setup_campaign` + `create_server_pilot` + host setup options; RESTORE: `create_campaign` (which unpacks the .sav, see F16) + `create_server_pilot` + restore setup options; JOIN: `create_client_pilot`. Then `initialise_regen_queues`, campaign & free-flight screens, → TRANSFERRING (gameflow.c:846-936).
6. **TRANSFERRING**: clients wait for their pilot entity; then **`flight()` runs the whole in-game session**; on exit, `GAME_STATUS_UNINITIALISED`, message log/population DB torn down, phases reset (gameflow.c:938-999).

`set_game_flow`/`get_game_flow` store a `game_flow_types` value (INSTANT_ACTION vs COMBAT_MISSIONS) — gameflow.c:94-109; nothing campaign-behavioral reads it beyond menu routing.

### SESSION-F12 — Campaign creation & campaign objectives
- `create_campaign(session)` (server-only, comms messages disabled during build): initialise division database and parser, then `parser_campaign_file(data_path\campaign_directory\campaign_filename)` builds the entire campaign entity tree (map size/sectors, factions, session, keysites, groups, members, tasks — all DATA-DRIVEN from the `.chc` script; reader: eech aphavoc/source/ai/parser/parsgen.c:243+); asserts a session entity now exists; attaches session sound effects — eech aphavoc/source/ai/faction/faction.c:111-158. `create_faction(side, colour)` creates a FORCE child of the session per `FACTION` tag (faction.c:234-261, parsgen.c:1221-1247).
- `setup_campaign()` (host only, **not** on restore — gameflow.c:889-891): for every force, choose campaign objectives, then `initialise_order_of_battle()` — eech aphavoc/source/ai/highlevl/setup.c:91-120.
- Objective selection (`create_force_campaign_objectives`, setup.c:126-289): candidate set = every enemy-force keysite with `INT_TYPE_POTENTIAL_CAMPAIGN_OBJECTIVE` and `INT_TYPE_IN_USE`; zero candidates is fatal. Rating = range to the closest same-side (enemy) keysite ≥ 1 km away (isolation measure), normalised by the highest, **plus frand1()** ("obligatory random factor", setup.c:257-263); list quicksorted; top `NUMBER_OF_CAMPAIGN_OBJECTIVES_PER_SIDE = 5` (setup.c:79) linked into the force's `LIST_TYPE_CAMPAIGN_OBJECTIVE`.

### SESSION-F13 — Campaign completion & victory conditions
Trigger points: `ENTITY_MESSAGE_CHECK_CAMPAIGN_OBJECTIVES` is sent to the owning force when a keysite is destroyed (eech aphavoc/source/entity/special/keysite/ks_dstry.c:367), when a keysite changes side/state (keysite.c:1441), and when a helicopter is destroyed (eech aphavoc/source/entity/mobile/aircraft/helicop/hc_dstry.c:639). There is **no periodic poll and no time-based end** — evaluation is purely event-driven.

Handler `response_to_check_campaign_objectives` (server-only; no-op if session already complete) — eech aphavoc/source/entity/special/force/fc_msgs.c:144-311. Victory for the receiving side if ANY of:
1. **CAMPAIGN_COMPLETED_OBJECTIVES (a)**: every keysite in the force's `LIST_TYPE_CAMPAIGN_OBJECTIVE` is satisfied — troop-insertion targets (per `keysite_database[].troop_insertion_target`, DATA-DRIVEN) must be owned by this side; all others must be dead (`!INT_TYPE_ALIVE`) (fc_msgs.c:180-211).
2. **CAMPAIGN_COMPLETED_OBJECTIVES (b)**: enemy force has **no** keysite with `air_force_capacity != NONE` that is both alive and in use (fc_msgs.c:222-249).
3. **CAMPAIGN_COMPLETED_VALID_GUNSHIPS**: enemy force's air registry contains no living player-controllable combat helicopter (`aircraft_database[].player_controllable` && `view_category == VIEW_CATEGORY_COMBAT_HELICOPTERS`) (fc_msgs.c:255-295).

`campaign_completed(side, complete)` — eech aphavoc/source/ui_menu/ingame/campaign/campaign.c:1096-1148: server logs "CAMPAIGN WON BY %s SIDE", transmits `ENTITY_COMMS_CAMPAIGN_COMPLETED` to clients (en_comms.c:626-641 packs side + `INT_TYPE_SESSION_COMPLETE`), and if game type is CAMPAIGN awards the session's campaign medal + increments successful tours (winning side is the player's) or failed tours; all machines set `INT_TYPE_SESSION_COMPLETE = complete` on the session and show the completed dialog. Dialog texts: winner side "Allied Victory" — OBJECTIVES → "Key Objectives Achieved", VALID_GUNSHIPS → "Enemy Air Forces Seriously Depleted"; loser side "Enemy Victory" — "Key Allied Installations Lost" / "Insufficient Resources Left For Conflict" (campaign.c:997-1090). The campaign **keeps running** after completion (session persists; the flag gates saving, mission selection and new-task UI — ca_menu.c:125, ca_selct.c:179/1367/1467, ca_brief.c:477/806, fc_msgs.c:163, helicop.c:590).

### SESSION-F14 — Campaign script events & triggers
The `.chc` parser supports an embedded scripting layer (all DATA-DRIVEN; reader `parser_campaign_file`, eech aphavoc/source/ai/parser/parsgen.c:243+): `CREATE_VARIABLE`/`SET_VARIABLE`/`CALCULATE` (int variables; operators + − * /, parsgen.c:2763-2814), `IF/ELSE/ENDIF`, `WHILE/END_WHILE`, `CALL` (include another script file), `CREATE_EVENT` (named script block at a file offset), `CREATE_TRIGGER` (binds a `campaign_trigger` type + params to an event), `SET_EVENT_TRIGGERED`, `END_CAMPAIGN` (reads a campaign-result enum; **sets nothing else** — parsgen.c:344-355), plus in-event `CREATE_GROUP`/`CREATE_MEMBERS`/`CREATE_TASK`.
- `update_campaign_triggers` runs every 1 s (highlevl.c:285) but as coded polls **only trigger type CAMPAIGN_TRIGGER_NONE** (the loop over all types is commented out — parsgen.c:218-237); when a trigger of the polled type "fires", its event's script block is executed via `parser_campaign_file` at the stored offset (parsgen.c:2395-2448).
- `trigger_triggered` conditions (parsgen.c:2588-2712): BALANCE_OF_POWER compares a hardcoded stub `balance_of_power = 50.0` against value2 (stub — never side-specific); TASK_COMPLETED/FAILED, OBJECT_*, INEFFICIENT_KEYSITE, WAYPOINT_REACHED, SECTOR_* return TRUE unconditionally; TIME_DURATION compares campaign elapsed days/hours/minutes/seconds component-wise (note: component-wise ≥, not total-seconds, parsgen.c:2637-2680); VARIABLE_CONDITION evaluates a script variable; RANDOM fires with probability 1/value1 per check.
- KEY_PRESS triggers are bound to keyboard events at load (`generate_key_bound_triggers`, parsgen.c:2455-2556).
Given the polling restriction, only triggers registered with type NONE (plus key-press bindings) can actually fire in-game; note this as partially dead machinery.

### SESSION-F15 — Save game (store_session + autosave)
`store_session(game_session, filename)` — eech aphavoc/source/ui_menu/session/uisession.c:752-1161:
- Writes two files under `data_path\campaign_directory\`: `<name>.sav` (binary) and `<name>.SCx` (script; extension = game-type extension with 'S' prefixed, uisession.c:792-799). Existing files are rotated to `_bak0.._bakN` up to `command_line_saves_copies` (default 0 → overwrite/delete; uisession.c:801-874, cmndline.c:265).
- Script file contents: TITLE; SHORT_TEXT with "Elapsed Time %d days, hh.mm.ss" from session elapsed_time (uisession.c:923-953); CAMPAIGN_DATA block re-listing side-data / population-placement / population filenames, map X/Z/sector sizes, and FACTION side+colour pairs in reverse list order so they reload in order (uisession.c:958-1018); `SAVED_CAMPAIGN` block with data path, campaign directory, original campaign filename (uisession.c:1024-1034); VERSION_NUMBER from session (uisession.c:1044-1055); SEASON (uisession.c:1061-1064).
- Binary `.sav`: 1 MB buffer (doubled on overflow) beginning with the int version number, then `pack_session(buffer, PACK_MODE_SERVER_SESSION)` (uisession.c:1076-1144). `PACK_MODE_SERVER_SESSION` asserts the session is **not complete** (ss_pack.c:252) — completed campaigns cannot be saved.
- **Autosave**: in the flight loop, server only, when `command_line_autosave > 0` and `time(NULL)` exceeds last save + interval, `store_session(session, "AUTOSAVE")`; code default 30 (seconds), EECH.INI value is entered in minutes (×60) — eech aphavoc/source/flight.c:505-515, cmndline.c:264, eechini.c:376.
- UI save: save page filename input is sanitised to alnum + " -_!()" max length, save button server-only and hidden once campaign complete — eech aphavoc/source/ui_menu/ingame/campaign/ca_save.c:146-166, 172-262, ca_menu.c:122-126.

### SESSION-F16 — Restore saved campaign
A restore session (`SESSION_LIST_TYPE_RESTORE`) goes through the normal gameflow HOST path except `setup_campaign()` is skipped (objectives were saved) — gameflow.c:861-877. `create_campaign` parses the saved **script** file, whose `SAVED_CAMPAIGN` tag reloads the binary: read path + filename, `fread` whole `.sav`, compare leading version int against `get_global_version_number()` (`debug_fatal` on mismatch), then `unpack_session(buffer, PACK_MODE_SERVER_SESSION)` — eech aphavoc/source/ai/parser/parsgen.c:2209+ and eech aphavoc/source/ai/faction/parser.c:2031-2114. (Gameflow's earlier script-header version check gives the user-facing "INVALID_SAVED_GAME" rejection, gameflow.c:511-538.)

### SESSION-F17 — Entity-tree serialisation (pack_session scope & session field sets)
`pack_session` (eech aphavoc/source/entity/system/en_comms/en_sessn.c:197-491) packs in fixed order: sectors, pylons, segments, bridges, **session**, each force, then every entity in the global entity list (terminated by ENTITY_TYPE_UNKNOWN marker), then keysite data, regen data, city buildings, scenics, sites, site-updatables, anti-aircraft, groups, division database, message log, group callsign database. Returns overflow flag so callers can grow the buffer. `unpack_session` mirrors it with progress-indicator updates and (client mode) AI-system reinitialisation (en_sessn.c:497-599+).

Session per-mode field sets (eech aphavoc/source/entity/special/session/ss_pack.c):
- SERVER_SESSION (save file): version_number, force list root, elapsed_time, lightning_timer, start_time, time_of_day_acceleration, fog_of_war_maximum_value, full weather + wind state, day_segment_type, population bounds, campaign_medal, campaign_requires_apache_havoc, auto_assign_gunship, infinite fuel/weapons, suppress_ai_fire, invulnerabilities, cheats_enabled, skip_night_time, weather/wind_increasing, local_weather_model (ss_pack.c:249-337). Not saved: session_complete (asserted false), time_of_day_resync, special effects.
- CLIENT_SESSION (MP join): all of the above **plus** entity safe ptr, session_complete and the special-effect list root (ss_pack.c:340-430).
- BROWSE_SESSION: minimal (version, force root, elapsed_time, start_time…) for the session browser (ss_pack.c:433-459+).
- UPDATE_ENTITY: the once-per-minute resync subset (see F7); unpacking it marks the campaign timer display valid (ss_pack.c:208, 727).

### SESSION-F18 — In-game campaign UI surface (data exposed / commands issued)
- Screen = `campaign_screen` with 10 pages (CAMPAIGN_PAGES, campaign.h:76-90); page switching keeps a history stack (campaign.c:225-320). Entered as the planner UI for CAMPAIGN/SKIRMISH game types (flight.c:182-194); dedicated servers use a separate screen.
- Top menu (eech aphavoc/source/ui_menu/ingame/campaign/ca_menu.c:104-204): Map, Sit. Rep. (stats), Options (pauses time acceleration on entry, ca_menu.c:228-233), Save (drawable only on server AND `INT_TYPE_SESSION_COMPLETE == CAMPAIGN_COMPLETED_FALSE`), Chat (only with MP connections), Briefing/Debriefing (label switches when player task state is TASK_STATE_COMPLETED), Weapon Loading (only with a gunship).
- Sit. Rep. page shows the player side's campaign objectives (LIST_TYPE_CAMPAIGN_OBJECTIVE): name plus Complete/Incomplete — troop-insertion targets complete when owned by player side, others complete when dead — eech aphavoc/source/ui_menu/ingame/campaign/ca_stat.c:130-226.
- Map: enemy GROUP map icons go stale — position not refreshed unless `time_since_last_update ≤ session_campaign_map_update_interval` (server-configurable, default 120 s; 0 disables staleness) — eech aphavoc/source/ui_menu/ingame/common/map.c:295-305, cmndline.c:278.
- Commands: Quit Mission dialog (accept clears gunship entity, forces debrief page if the player task completed) — campaign.c:345-447; Quit Campaign dialog (accept calls `player_quit_session`) — campaign.c:459-550; campaign-complete dialog (F13 texts) with dismiss button — campaign.c:326-333, 997-1090.
- Campaign countdown timer display (`T-mm:ss` from force campaign-criteria days/hours vs session elapsed time, clients only after first resync) exists but the drawing code is **commented out / dead** — eech aphavoc/source/entity/special/force/force.c:490-561.

### SESSION-F19 — Realism / cheat / configuration flags on the session
Set from host setup options at campaign start: INT_TYPE_INFINITE_FUEL, INFINITE_WEAPONS, INVULNERABLE_FROM_COLLISIONS, INVULNERABLE_FROM_WEAPONS, SUPPRESS_AI_FIRE (per game type) — eech aphavoc/source/ui_menu/sessparm/sparm_sc.c:1616-1653. DATA-DRIVEN from the campaign file: AUTO_ASSIGN_GUNSHIP (reader parsgen.c:426-442), MEDAL → INT_TYPE_CAMPAIGN_MEDAL (parsgen.c:981-991), CAMPAIGN_REQUIRES_APACHE_HAVOC (parsgen.c:960-979), SUPPRESS_AI_FIRE (reader eech aphavoc/source/ai/faction/parser.c:690-705), SEASON (parsgen.c:2189). `INT_TYPE_CHEATS_ENABLED` getter returns FALSE whenever any MP connection exists, TRUE if `command_line_cheats_on`, else the stored flag — eech aphavoc/source/entity/special/session/ss_int.c:332-349. Population-area check `check_point_inside_population_area` tests a point against the session's population rectangle — session.c:944-965.

### SESSION-F20 — Session teardown / campaign destruction
Destroy-family on the session destroys all force children (hence the entire campaign tree) and its sound effects, then the session itself (ss_dstry.c:201-221); plain destroy asserts the force list is already empty, removes the session from the update list, unlinks special effects and clears the global pointer (ss_dstry.c:79-133). `destroy_campaign()` frees the campaign/population/side-data filename strings, resets route data, deinitialises parser and division database — eech aphavoc/source/ai/faction/faction.c:164-203. On flight exit: AI system stopped (scheduler emptied), gunship/pilot cleared, pack buffer closed — flight.c:545-584.

## 4. Interactions

- **F3 scheduler → everything**: task generation (taskgen spec), imaps (imap spec), fog of war and sector census (sector spec), campaign triggers all run off `add_update_function`; their phase offsets are aligned to session `elapsed_time` (F4), so restoring a save preserves the firing phase.
- **F2 update list ← groups/keysites/regen**: campaign entities self-schedule per-frame time via LIST_TYPE_UPDATE + `FLOAT_TYPE_SLEEP` countdowns (group example cited; keysite/regen equivalents in their specs).
- **F4 time → F13/F14/F15**: TIME_DURATION script triggers and the save-file "Elapsed Time" text read `FLOAT_TYPE_ELAPSED_TIME`; day segment drives rendering only (no campaign consumer found).
- **F6 frame acceleration** multiplies everything (entity updates, scheduler, comms receive); **F5 clock acceleration** multiplies only time-of-day.
- **F12 objectives → F13 win check → UI (F18)**: objective keysites chosen at setup are the exact set tested by the completion handler and listed on the Sit. Rep. page.
- **F13 session_complete** gates: saving (ss_pack assert + UI), new mission selection (ca_selct), force task generation (fc_msgs.c:163), helicopter respawn logic (helicop.c:590).
- **F1 fog_of_war_maximum_value** is consumed by the sector fog-of-war decay system (highlevl/sector spec).
- **F8 weather** is queried by flight dynamics/visibility elsewhere; campaign-file weather tags interact with host setup options (fixed weather suppresses the RANDOM option).

## 5. Port mapping

(From the port summary only; the DCS port has 22 Lua modules, a plain-timer game_loop, DCS mission time, no save/load, and a 4 h campaign timeout in win_condition.)

| Feature | Status | Note |
|---|---|---|
| SESSION-F1 session entity & defaults | PROXY | No entity system; campaign_state module holds global campaign state (strength census, phases) instead of a session entity. |
| SESSION-F2 per-frame update list | PROXY | game_loop is a plain timer loop; no dynamic update-list membership / sleep mechanism. |
| SESSION-F3 timed scheduler & cadence table | PARTIAL | imap module reproduces the 4 imap layers at 120 s with 20 s stagger; fog_of_war module exists; task-generation cadences NOT ported (task engine not ported — attack_waves/cas_bai_sead are proxies with their own timing). |
| SESSION-F4 game time / day segments / start time | PROXY | DCS mission time used directly; no elapsed-time entity field, no day-segment model, no random/preset start-time table. |
| SESSION-F5 demo night-skip & clock accel | NOT PORTED | No time-of-day acceleration in port. |
| SESSION-F6 frame-level time acceleration | NOT PORTED | Port explicitly has no acceleration. |
| SESSION-F7 MP session resync | NOT PORTED | MP/player layer not ported; DCS handles time sync natively. |
| SESSION-F8 weather model | NOT PORTED | DCS mission weather; no roving-storm model module. |
| SESSION-F9 wind model & gusting | NOT PORTED | DCS native wind. |
| SESSION-F10 lightning timer | NOT PORTED | Presentation; DCS native. |
| SESSION-F11 gameflow state machine | PROXY | main + game_loop replace the phase machine; no scenario/briefing/restore phases. |
| SESSION-F12 campaign creation & objectives | PARTIAL | keysite/installations/frontline modules build the war; the 5-objective-keysite selection (isolation rating + random, top 5) has no evident counterpart — win_condition uses captured sectors instead. |
| SESSION-F13 completion & victory | PARTIAL | win_condition has 3 criteria (captured sectors, balance of power, 4 h time). EECH's criteria differ: objective-keysite set, enemy-airbase elimination, enemy-gunship elimination — and EECH has NO time-based end; the 4 h timeout is a port invention. Event-driven check vs polled: UNKNOWN. |
| SESSION-F14 script triggers/events | NOT PORTED | No campaign-file scripting layer in port. |
| SESSION-F15 save game / autosave | NOT PORTED | Port has no persistence (explicit). |
| SESSION-F16 restore | NOT PORTED | As above. |
| SESSION-F17 pack_session serialisation | NOT PORTED | As above (persistence). |
| SESSION-F18 campaign UI surface | PARTIAL | map_overlay + imap + fog_of_war expose map data; no campaign screen/pages, no objective Sit. Rep., no save UI; enemy-marker staleness interval (120 s) — fog_of_war may proxy this: UNKNOWN. |
| SESSION-F19 realism/cheat/config flags | NOT PORTED | No session flags layer; DCS options govern realism. |
| SESSION-F20 teardown | NOT PORTED | Mission end handled by DCS; no explicit teardown needed. |

## 6. Open questions

1. **Two campaign parsers**: `ai/parser/parsgen.c` (used by `create_campaign`) and `ai/faction/parser.c` both implement `FILE_TAG_*` handling; parsgen.c:3217 labels a section "OLD PARSER". Which handlers in faction/parser.c (e.g. FILE_TAG_TIME, FILE_TAG_TOUR_OF_DUTY, FILE_TAG_WEATHER at parser.c:707-819) are actually reachable from the live parse path was not fully traced.
2. **FILE_TAG_TIME / FILE_TAG_TOUR_OF_DUTY are silent no-ops on the session**: they call `set_local_entity_float_value(session, FLOAT_TYPE_TIME_OF_DAY / FLOAT_TYPE_TOUR_OF_DUTY_TIME, …)` (parser.c:748, 767) but ENTITY_TYPE_SESSION registers no setter for either type (ss_float.c:504-510 registers only the getter for TIME_OF_DAY), and the entity-system default setter is an empty function (en_float.c:1564-1566). So campaign files apparently cannot set a fixed start time this way — unless a FORCE-level tour-of-duty setter (force entity) is the intended receiver. Needs tracing in the force spec.
3. **update_campaign_triggers polls only CAMPAIGN_TRIGGER_NONE** (the all-types loop is commented out, parsgen.c:218-237), and most trigger conditions return TRUE unconditionally (parsgen.c:2620-2635). How much of the scripting layer ever functioned in shipped campaigns is unclear; BALANCE_OF_POWER is an explicit stub (`balance_of_power = 50.0`, parsgen.c:2604-2618).
4. **FILE_TAG_END_CAMPAIGN** reads a campaign-result enum but performs no state change (parsgen.c:344-355) — scripted campaign termination appears unimplemented.
5. **Campaign countdown timer** rendering in force.c:490-561 is commented out; whether any force "campaign criteria" (days/hours) end-condition logic remains live belongs to the force spec.
6. **command_line_autosave units**: code default 30 with a seconds comparison (flight.c:508) but EECH.INI multiplies the entered value by 60 (eechini.c:376) — the effective shipped default (30 s vs 30 min) depends on whether the ini writes the value back; not resolved here.
7. `session_planner_goto_button`, `session_vector_flight_model`, `session_camcom` etc. (gameflow.c:748-762) are server-side option globals whose consumers were not traced (mostly avionics/UI, out of scope).
8. Whether `weather_mode_transitional_period` is ever set from campaign data (only the 60 s default and pack/unpack were found) — the `WEATHER` tag sets position/velocity/radius only.
