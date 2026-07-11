# EECH Spec 06 — Sectors, Fog of War, Influence Maps & Frontline

Sources:
- `aphavoc/source/entity/special/sector/sector.h`, `sector.c`, `sc_seccreat.c`, `sc_msgs.c`, `sc_int.c`, `sc_list.c`
- `aphavoc/source/entity/system/en_main/en_world.h`, `en_world.c`
- `aphavoc/source/ai/highlevl/imaps.h`, `imaps.c`, `highlevl.c`, `highlevl.h`, `reaction.c`
- `aphavoc/source/ai/frontl/ai_fline.c`, `ai_fline.h`
- `aphavoc/source/ai/ai_misc/ai_sect.c`, `ai_route.c`, `ai_route.h`, `ai_dbase.c`
- `aphavoc/source/ai/faction/parser.c`, `popread.c`, `faction.c`
- `aphavoc/source/entity/special/keysite/ks_dbase.c`, `ks_float.c`, `ks_creat.c`, `ks_dstry.c`, `keysite.c`
- `aphavoc/source/entity/mobile/aircraft/ac_dbase.c`, `ac_float.c`; `entity/mobile/vehicle/vh_dbase.c`, `vh_float.c`
- `aphavoc/source/entity/special/session/ss_creat.c`; `cmndline.c`; `eechini.c`; `modules/maths/constant.h`

All paths below are relative to `E:\eech_source_code\aphavoc\source\` unless prefixed `modules/`.

---

## 1. Overview

EECH divides the campaign map into a rectangular grid of **sector entities** (local-only, one per grid cell). Sectors are the spatial substrate for almost all campaign-level AI:

- Every mobile/fixed entity is linked as a child of the sector it occupies (`LIST_TYPE_SECTOR`). Link/unlink events drive per-sector accumulation of threat values and fog-of-war grants.
- Each sector carries per-side float fields: dynamic control influence (`sector_side`), fog of war (`fog_of_war`), keysite importance (`importance_level`), distance-to-friendly-base (`distance_to_friendly_base`), and surface-to-air / surface-to-surface defence levels. These raw fields are periodically **normalised** into four byte-valued **influence maps (imaps)** which the high-level task generator samples when scoring candidate tasks.
- **Fog of war** is a per-side, per-sector *awareness timer* measured in seconds (default max 4 hours). Any live aircraft or vehicle entering a sector stamps awareness for its side in surrounding sectors out to twice its database `recon_radius`, with linear falloff. A periodic update (every 30 s) decays every sector's awareness by 30 s.
- The **frontline** is a list of sectors of one side that touch (8-neighbourhood) a sector of another side, computed from the *static* painted sector ownership. It is computed once at campaign load and drives the initial placement of primary/secondary/artillery frontline ground groups on road nodes. During play, ground advance/retreat is driven by imaps and road-node occupancy, not by recomputing the frontline.
- `ai_route.c` loads the road-node graph (nodes, links, per-link waypoint polylines, bridge "breaks") that frontline placement and ground-group advance/retreat consume.

Nothing in the sector system stores supply; supply levels live on keysites (see keysite/supply spec). The sector's only keysite-related field is a `keysite_count` counter.

---

## 2. Data model

### 2.1 `struct SECTOR` — eech `entity/special/sector/sector.h:67-88`

| Field | Type | Notes |
|---|---|---|
| `sector_root` | list_root | children linked via `LIST_TYPE_SECTOR` (all entities positioned in this sector) — eech sector.h:70, sc_list.c:87 |
| `sector_task_root` | list_root | tasks targeted at this sector (`LIST_TYPE_SECTOR_TASK`) — eech sector.h:71, sc_list.c:89 |
| `special_effect_root` | list_root | special effects in sector — eech sector.h:72, sc_list.c:91 |
| `keysite_count : 8` | bitfield | number of keysites in sector — eech sector.h:75 |
| `x_sector : NUM_SECTOR_BITS`, `z_sector : NUM_SECTOR_BITS` | bitfield | grid coordinates; `NUM_SECTOR_BITS` = 8 (max 256×256 grid) — eech sector.h:76-77, en_funcs/en_int.h:495 |
| `side : NUM_SIDE_BITS` | bitfield | **static** painted ownership (`INT_TYPE_SIDE`) — eech sector.h:78 |
| `tallest_structure_height` | float | max fixed-structure top height in sector — eech sector.h:81 |
| `sector_side [NUM_ENTITY_SIDES]` | float | dynamic control influence per side (keysite-driven) — eech sector.h:82 |
| `fog_of_war [NUM_ENTITY_SIDES]` | float | per-side awareness timer, seconds — eech sector.h:83 |
| `importance_level [NUM_ENTITY_SIDES]` | float | raw importance accumulation — eech sector.h:84 |
| `distance_to_friendly_base [NUM_ENTITY_SIDES]` | float | 0..1 proximity value (1 = at a base) — eech sector.h:85 |
| `surface_to_air_defence_level [NUM_ENTITY_SIDES]` | float | raw S-A threat accumulation — eech sector.h:86 |
| `surface_to_surface_defence_level [NUM_ENTITY_SIDES]` | float | raw S-S threat accumulation — eech sector.h:87 |

All fields zeroed at creation (`memset`, eech sc_seccreat.c:236).

Access: global `entity **entity_sector_map` (eech sector.c:81-82), indexed `[x + z*NUM_MAP_X_SECTORS]` via `get_local_raw_sector_entity` macro (eech sector.h:105/109). Position→sector: `get_local_sector_entity` (eech sector.c:103-127) using `get_x_sector`/`get_z_sector` macros = integer divide by `SECTOR_SIDE_LENGTH` (eech en_world.h:141,143).

### 2.2 World-map grid parameters — eech `entity/system/en_main/en_world.h`, `en_world.c`

- `SECTOR_SIDE_LENGTH` = `world_map.sector_side_length`, **data-driven** per map: campaign file tags `FILE_TAG_MAP_X_SIZE` / `FILE_TAG_MAP_Z_SIZE` / `FILE_TAG_MAP_SECTOR_SIZE` → `set_entity_world_map_size (x_size, z_size, sector_size)` (reader: eech ai/faction/parser.c:331-347; also parsgen.c:1103, comm_man.c:1617). Must be a power of two (comment eech en_world.h:70; `ASSERT (int_bit_count(...)==1)` eech en_world.c:92).
- `NUM_MAP_X_SECTORS`/`NUM_MAP_Z_SECTORS`, `MIN/MAX_MAP_X/Z_SECTOR` macros — eech en_world.h:105-116. Map extent = `num_sectors * sector_side_length − 1.0` (eech en_world.c:113-115).
- Grid ceiling: 8-bit sector coords (eech en_int.h:495) and the frontline scratch array `frontline_sectors_arrangements[128*128]` (eech ai_fline.c:109).

### 2.3 Derived sector int values — eech `entity/special/sector/sc_int.c`

- `INT_TYPE_SIDE` — raw static side; DEBUG build asserts it is only set to a non-neutral value while `GAME_STATUS_INITIALISING` (eech sc_int.c:103-118), i.e. **static ownership never changes after campaign init**.
- `INT_TYPE_SECTOR_SIDE` — *computed* on read: `BLUE` if `sector_side[BLUE] > sector_side[RED]` else `RED` (eech sc_int.c:229-239). No neutral result; a tie (including 0/0) reads as RED.
- `INT_TYPE_X_SECTOR` / `INT_TYPE_Z_SECTOR` / `INT_TYPE_KEYSITE_COUNT` — plain accessors (eech sc_int.c:95-134, 200-270).

### 2.4 Influence-map storage — eech `ai/highlevl/imaps.c`, `imaps.h`

```
enum IMAP_TYPES { IMAP_IMPORTANCE, IMAP_BASE_DISTANCE, IMAP_AIR_DEFENCE, IMAP_SURFACE_DEFENCE, NUM_IMAP_TYPES };  // eech imaps.h:70-78
static unsigned char **imaps [NUM_IMAP_TYPES];   // [type][side][z*NUM_MAP_X_SECTORS + x], eech imaps.c:81-82
static float *imap_temp_array;                   // scratch, eech imaps.c:84-85
```
Allocated per side at `initialise_imaps` (eech imaps.c:94-117), server-only, at `start_high_level_ai` (eech highlevl.c:201). Sampled by `get_imap_value` → byte/255.0 ∈ [0,1] (eech imaps.c:156-169).

### 2.5 Keysite database fields feeding sectors/imaps — eech `entity/special/keysite/ks_dbase.h:79-82`, values `ks_dbase.c`

Hardcoded per keysite sub-type (overridable by mod ini readers, eech wutcfg.c:510-513, gwutcfg.c:1487-1490):

| Keysite type | importance | importance_radius | air_coverage_radius | sector_side_max_value | source (ks_dbase.c) |
|---|---|---|---|---|---|
| AIRBASE | 1.0 | 80 km | 400 km | 80.0 | eech ks_dbase.c:102,104,105,107 |
| ANCHORAGE (Carrier) | 1.0 | 60 km | 100 km | 50.0 | eech ks_dbase.c:149,151,152,154 |
| FACTORY | 0.5 | 40 km | 0 km | 20.0 | eech ks_dbase.c:196,198,199,201 |
| FARP | 0.4 | 40 km | 100 km | 40.0 | eech ks_dbase.c:243,245,246,248 |
| MILITARY_BASE | 0.8 | 30 km | 0 km | 30.0 | eech ks_dbase.c:290,292,293,295 |
| PORT | 0.2 | 20 km | 0 km | 20.0 | eech ks_dbase.c:337,339,340,342 |
| POWER_STATION | 0.3 | 30 km | 0 km | 0.0 | eech ks_dbase.c:384,386,387,389 |
| OIL_REFINERY | 0.4 | 30 km | 0 km | 20.0 | eech ks_dbase.c:431,433,434,436 |
| RADIO_TRANSMITTER | 0.5 | 30 km | 0 km | 30.0 | eech ks_dbase.c:478,480,481,483 |

Entity accessors: `FLOAT_TYPE_KEYSITE_IMPORTANCE` (eech ks_float.c:293-299), `FLOAT_TYPE_SECTOR_SIDE_MAX_VALUE` (eech ks_float.c:333-339).

### 2.6 Unit database fields feeding FOW/imaps (data-driven)

- `recon_radius` — aircraft: `aircraft_database[sub_type].recon_radius` via `FLOAT_TYPE_RECON_RADIUS` (reader eech ac_float.c:582-585; field ac_dbase.h:142); vehicles: `vehicle_database[...]` (reader eech vh_float.c:478-481; field vh_dbase.h:127). Mod-ini overridable ("Recon Radius {m}" eech wutcfg.c:250; "Recon Range {m}" eech wutcfg.c:352).
- `potential_surface_to_air_threat`, `potential_surface_to_surface_threat`, `air_scan_range`, `surface_scan_range` — vehicle database (readers eech vh_float.c:302-306, 446-458, 494-498).

### 2.7 Session FOW maximum — eech `entity/special/session/ss_creat.c`

`raw->fog_of_war_maximum_value = command_line_fog_of_war_maximum_value` (eech ss_creat.c:191), then `bound (value, 8.0*FOG_OF_WAR_DECAY_RATE, 8.0*ONE_HOUR)` = [240 s, 28 800 s] (eech ss_creat.c:213). Default `DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE = 4.0 * ONE_HOUR` = 14 400 s (eech ai/highlevl/highlevl.h:69; cmndline.c:313), user-configurable via eech.ini (eech eechini.c:914). Exposed as `FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE` on the session entity (eech ss_float.c:103-106, 462-466).

### 2.8 Road-node graph — eech `ai/ai_misc/ai_route.h:98-153`

```
link_data      { int cost; node:14; breaks:5; }                                   // eech ai_route.h:98-107
node_data      { node:14; safe_radius:14; number_of_links:7; visited:7;
                 side_occupying:2; side_aware:2; side_exploring:2; link_data *links; }  // eech ai_route.h:115-129
node_link_data { source, destination, path_type, number_of_links (u16); vec3d *link_positions; } // eech ai_route.h:137-151
```
Loaded from per-theatre binary files `route\ROADS.dat/.nde/.wp` (fallback `ROADDATA.*`) — eech ai_route.c:293-314, 357, 565, 663. `MAX_ROUTE_LENGTH` = 100 (eech ai_route.h:69).

### 2.9 Frontline scratch structure — eech `ai/frontl/ai_fline.c:81-109`

`frontline_arrangements { int x, z; entity *sector; unsigned char adjacent_count, inserted; }`, static array `[128*128]`. Output: sectors linked into the force entity's `LIST_TYPE_SECTOR_FRONTLINE` child list (eech ai_fline.c:322-324). Enum `FRONTLINE_SECTOR_TYPES { NONE, PRIMARY }` (eech ai_extrn.h:194-202).

---

## 3. Features

### SECTOR-F1 — Sector grid creation

**Behavior.** At campaign load (and world re-size), `create_local_sector_entities` frees any previous grid, allocates `entity_sector_map[NUM_MAP_X_SECTORS * NUM_MAP_Z_SECTORS]` and creates one local-only `ENTITY_TYPE_SECTOR` per cell with `INT_TYPE_X_SECTOR`/`INT_TYPE_Z_SECTOR` attributes (eech sc_seccreat.c:87-182, creation loop 166-179). Sector entities are created *before* any client/server entities so entity indices match across machines (comment eech sc_seccreat.c:78-83). All raw data initialised to zero (eech sc_seccreat.c:236).

Grid dimensions and cell size come from the campaign file (see §2.2). Cell size must be a power of two.

| Constant | Value | Source |
|---|---|---|
| `NUM_SECTOR_BITS` | 8 | eech en_funcs/en_int.h:495 |
| sector grid dims / cell size | data-driven per theatre | reader eech ai/faction/parser.c:331-347 |
| power-of-two cell size | `ASSERT int_bit_count(sector_side_length)==1` | eech en_world.c:92 |

**Trigger/cadence.** Once per campaign load / map-size change.

### SECTOR-F2 — Sector membership, tallest structure, and per-sector task list

**Behavior.** Entities are linked as `LIST_TYPE_SECTOR` children of their sector; a validation pass asserts each child's position maps back to that sector (eech sector.c:329-368). On `ENTITY_MESSAGE_LINK_CHILD` with `LIST_TYPE_SECTOR` (eech sc_msgs.c:79-229):
1. Fixed entities update `tallest_structure_height` = max of (entity y + bounding-box ymax) (eech sc_msgs.c:128-145).
2. `add_mobile_values_to_sector` (eech sc_msgs.c:151) — see SECTOR-F12/F13.
3. If sender is an aircraft or vehicle (eech sc_msgs.c:159-161) with non-neutral side (171-174): FOW grant (`set_sector_fog_of_war_value`, 178, see SECTOR-F6), then (server, game initialised) both forces are notified `ENTITY_MESSAGE_FORCE_ENTERED_SECTOR` (eech sc_msgs.c:210-224).

On `UNLINK_CHILD`: `remove_mobile_values_from_sector` (eech sc_msgs.c:235-255) reverses the threat contributions.

`get_sector_task_type_count` counts `LIST_TYPE_SECTOR_TASK` children by task sub-type and side (eech sector.c:639-685) — used by task generation to cap per-sector task counts (e.g. `MAX_SECTOR_SEAD_TASK_COUNT` = 1, eech highlevl.c:100).

**Trigger/cadence.** Event-driven on every sector crossing / creation / destruction.

### SECTOR-F3 — Static sector ownership (painted sides)

**Behavior.** `raw->side` (`INT_TYPE_SIDE`) is loaded once at campaign creation from the theatre side file: a PSD image whose pixels are force colours (`read_sector_side_file`, eech ai/faction/popread.c:341-417; pixel dimensions must equal the sector grid, popread.c:371-372; all sectors first reset to `ENTITY_SIDE_NEUTRAL`, popread.c:446) or a raw int-per-sector `.DAT` (`load_ai_sector_data`, eech ai/ai_misc/ai_dbase.c:119-166). Selected by filename extension (eech parser.c:464-473).

A DEBUG assert forbids setting a non-neutral side after `GAME_STATUS_INITIALISING` (eech sc_int.c:108-115). The only in-play writer is `add_sector_to_frontline` re-asserting the same side on frontline sectors (eech ai_fline.c:233). **Static ownership is effectively immutable during the campaign**; dynamic control is SECTOR-F4.

### SECTOR-F4 — Dynamic sector control (`sector_side` influence, `INT_TYPE_SECTOR_SIDE`)

**Behavior.** Each in-use keysite projects control influence over the whole map. `update_imap_sector_side (en, in_use)` (eech imaps.c:335-399):

```
max_val = keysite sector_side_max_value          (eech imaps.c:357; db §2.5)
constant = 0.3                                   (eech imaps.c:361)
for every sector (x,z) on the map:               (eech imaps.c:383-397)
    dx = 0.3*|x - sx| + 1.0 ; dz = 0.3*|z - sz| + 1.0
    scale = max_val / (dx² + dz²)                (eech imaps.c:385-393)
    sector_side[side] += scale   (in_use)  or  -= scale  (not in_use)   (eech imaps.c:308-319)
```

Callers: keysite creation (eech ks_creat.c:239), destruction (eech ks_dstry.c:333), capture/side-change (eech keysite.c:1330 remove-old / 1351 add-new; also 549), faction setup (eech faction.c:388, 620, 1025), client updates (eech ks_pack.c:347, 387, 413). So control shifts **only when keysites change hands / are built / destroyed** — never from unit movement.

Consumers: `INT_TYPE_SECTOR_SIDE` = side with larger `sector_side` (eech sc_int.c:229-239); `get_local_sector_side_ratio` = `sector_side[side] / (blue+red)` with `ASSERT total > 0` (eech sector.c:298-323) — used as a "friendly territory" rating term in BAI scoring (eech highlevl.c:681).

| Constant | Value | Source |
|---|---|---|
| falloff constant | 0.3 per sector of Chebyshev-ish distance | eech imaps.c:361 |
| falloff shape | `max_val / (dx²+dz²)`, full-map extent | eech imaps.c:385-393 |
| per-keysite weight | `sector_side_max_value` 0–80 (see §2.5) | eech ks_dbase.c:107 etc. |

**Trigger/cadence.** Event-driven (keysite lifecycle). No decay, no normalisation of `sector_side` itself.

### SECTOR-F5 — Sector side count (per-force totals)

**Behavior.** `update_sector_side_count` iterates all sectors, tallies `INT_TYPE_SECTOR_SIDE` per side, stores in each force's `INT_TYPE_FORCE_SECTOR_COUNT` (eech sector.c:579-616). Server wrapper broadcasts `ENTITY_COMMS_UPDATE_SECTOR_SIDE_COUNT` (eech sector.c:622-633; client handler en_comms.c:2819/5535). Consumed by campaign status UI (eech ui_menu/ingame/campaign/ca_stat.c:724-726) and captured/lost-sector campaign criteria.

**Trigger/cadence.** Registered at `start_high_level_ai`: every **60 s** (`1.0 * ONE_MINUTE`), start-time anchor 15 s (eech highlevl.c:282; also once at startup, highlevl.c:211). `ONE_MINUTE` = 60 (eech modules/maths/constant.h:163,145).

### SECTOR-F6 — Fog-of-war grant (unit presence stamps awareness)

**Where values live:** on the **sector** entity, `fog_of_war[side]` (eech sector.h:83) — *not* on keysites. Units of measure: **seconds of remaining awareness** (max = session FOW max, default 14 400 s).

**Grant rule.** Sole granting path is `set_sector_fog_of_war_value`, called only from the sector `LINK_CHILD` response (eech sc_msgs.c:178) — i.e. whenever a live (eech sector.c:415-418), non-neutral (sc_msgs.c:171) **aircraft or vehicle** (sc_msgs.c:159-161) enters a new sector. There is no grant from engagements, sightings, or recon-task bookkeeping — recon tasks reveal territory simply by flying the aircraft through sectors. Formula (eech sector.c:374-504):

```
maximum_value = session FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE          (sector.c:424)
recon_radius  = entity FLOAT_TYPE_RECON_RADIUS * 2.0                 (sector.c:434)   <-- effective radius = 2x database value
sector_radius = int(recon_radius) / SECTOR_SIDE_LENGTH + 1           (sector.c:436-440)
for each sector in the (2*sector_radius+1)^2 box, clipped to map:    (sector.c:445-459)
    own sector:            new = maximum_value                        (sector.c:478-481)
    other sectors:  r = approx 3D range(sector centre, unit pos)      (sector.c:486)
                    if r <= recon_radius:
                        new = max(current, (1 - r/recon_radius) * maximum_value)   (sector.c:488-491)
    write only if new > current                                       (sector.c:496-499)
```

So the sector the unit stands in gets full awareness (4 h by default); surrounding sectors get linearly less, reaching 0 at 2× the database recon radius. Values only ever increase here; decay is SECTOR-F7.

### SECTOR-F7 — Fog-of-war decay and read semantics

**Decay.** `update_sector_fog_of_war` subtracts `FOG_OF_WAR_DECAY_RATE` from both sides' values in every sector, floored at 0 (eech sector.c:533-556, subtraction 552-553). Server wrapper broadcasts `ENTITY_COMMS_UPDATE_FOG_OF_WAR` so clients run the same decay (eech sector.c:562-573; client handler en_comms.c:2774/5492).

| Constant | Value | Source |
|---|---|---|
| `FOG_OF_WAR_DECAY_RATE` | 30.0 (seconds; both decrement and update interval) | eech ai/highlevl/highlevl.h:67 |
| decay cadence | every 30 s (`add_high_level_ai_function(update_client_server_sector_fog_of_war, FOG_OF_WAR_DECAY_RATE, 8.0)`) | eech highlevl.c:280 |
| `DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE` | 4.0 × ONE_HOUR = 14 400 s | eech highlevl.h:69; constant.h:166 |
| session clamp | [8×30 s, 8×3600 s] = [240 s, 28 800 s] | eech ss_creat.c:213 |

Because the decrement equals the interval, `fog_of_war` behaves as a real-time countdown: a fully-stamped sector stays known for `maximum_value` seconds (4 h) after last visit.

**Read.** `get_sector_fog_of_war_value` returns the stored timer, **except** when the sector's dynamic control side (`INT_TYPE_SECTOR_SIDE`) equals the querying side, in which case it returns the maximum (friendly-controlled territory is always fully visible) — eech sector.c:510-527 (override 519-522).

### SECTOR-F8 — Real per-category recon/vision radii (VERIFY result for port)

The DCS port's "airplane 20 km / heli 10 km / ground 3 km" **do not exist as constants anywhere in EECH.** EECH has one per-unit-type database float, `recon_radius`, and the FOW code doubles it (eech sector.c:434). Actual database values:

**Aircraft** (eech ac_dbase.c; distribution: 14×5000, 10×3000, 4×6000, 5×10000):

| Category (examples) | `recon_radius` | effective FOW radius (×2) | example source |
|---|---|---|---|
| Attack/scout/utility helicopters (AH-64D, Mi-28N, RAH-66, Ka-52, UH-60L, Mi-24V, Ka-50, OH-58D, AH-1x, Mi-17, Ka-29) | 5 000 m | 10 000 m | eech ac_dbase.c:144, 221, 298, 375, 454, 533 |
| Transport helicopters / transports (CH-46E, CH-3, CH-47D, Mi-6, MV-22, CH-53E, C-17, Il-76, C-130J, An-12B) | 3 000 m | 6 000 m | eech ac_dbase.c:610, 764, 918, 995, 2007, 2237-2545 |
| Attack jets (A-10A, Su-25, AV-8B, Yak-41) | 6 000 m | 12 000 m | eech ac_dbase.c:1072, 1149, 1380, 1457 |
| Fighters/strike fighters (F-16C, MiG-29, F/A-18C, Su-33, Su-34) | 10 000 m | 20 000 m | eech ac_dbase.c:1226, 1303, 1534, 1611, 1689 |

**Vehicles/ships** (eech vh_dbase.c; distribution: 10×500, 19×1000, 9×2000, 3×3000, 2×4000, 3×6000, 2×8000):

| Category | `recon_radius` | effective FOW radius | example source |
|---|---|---|---|
| Infantry/small units | 500 m | 1 000 m | eech vh_dbase.c:2104, 2290, 2538+ |
| Tanks, trucks, most AFVs | 1 000 m | 2 000 m | eech vh_dbase.c:554, 616, 740+ |
| APC/IFV class | 2 000 m | 4 000 m | eech vh_dbase.c:120, 182, 368+ |
| Scout/recon vehicles | 3 000 m | 6 000 m | eech vh_dbase.c:244, 306, 1174 |
| AD radar vehicles (e.g. M1097 Avenger tier) | 4 000 m | 8 000 m | eech vh_dbase.c:1050, 1112 |
| Radar SAM / frigates (SA-19; O.H. Perry, Krivak II) | 6 000 m | 12 000 m | eech vh_dbase.c:988, 1794, 1856 |
| Capital ships (Tarawa, Kiev) | 8 000 m | 16 000 m | eech vh_dbase.c:1670, 1732 |

**Verdict:** the port's 30 s decay tick **is** EECH-faithful (SECTOR-F7). The 20/10/3 km category radii are **inventions**, but coincidentally close to EECH's *effective* (2×) radii for the most common types: fighters 20 km, attack helicopters 10 km; ground is 1–4 km typical (not a flat 3 km), with recon/AD/ship outliers up to 16 km. A faithful port keys radius off the unit's database `recon_radius × 2` with linear falloff, and must also grant the *full* timer only in the occupied cell.

### SECTOR-F9 — Fog-of-war consumers and thresholds

All comparisons are against fractions of the session maximum (server-side task generation):

| Consumer | Condition | Source |
|---|---|---|
| CAS target selection | sector known: FOW > 0.5 × max | eech highlevl.c:757 |
| Recon-task worthiness (keysite strike) | keysite is `recon_target` OR FOW < 0.25 × max ⇒ needs recon first | eech highlevl.c:1179 |
| OCA strike / OCA sweep / SEAD target gating | FOW ≥ 0.25 × max | eech highlevl.c:1433, 1620, 2072 |
| Troop insertion recon gating | `recon_target` OR FOW < 0.2 × max | eech highlevl.c:1819 |
| SEAD around keysite | FOW > 0.25 × max | eech highlevl.c:2653 |
| Artillery strike | FOW > 0.25 × max | eech highlevl.c:3062 |
| Group reaction (reinforcement) | FOW > 0.5 × max | eech ai/highlevl/reaction.c:780 |
| Task objective info | "FOW known" if raw value > 0.1 (seconds) | eech entity/special/task/task.c:1534, 1620 |
| In-game map fog shading | keysite visible if raw value > 0.25; shade `140*(1 − fow/max)` | eech ui_menu/ingame/common/map.c:1396, 4295 |
| Tacview export filter | hide if FOW ≤ 0.25 (raw) | eech tacview/tacview.c:640 |

### SECTOR-F10 — IMAP_IMPORTANCE layer

**Raw accumulation.** Per in-use keysite: `update_imap_importance_level (en, in_use)` (eech imaps.c:454-530).

```
importance = keysite FLOAT_TYPE_KEYSITE_IMPORTANCE                 (imaps.c:478)
sector_radius = max(1, int(importance_radius / SECTOR_SIDE_LENGTH))  (imaps.c:486-490)
for offsets (x,z) in square, clipped to map:                        (imaps.c:505-517)
    scale = (x² + z²) / sector_radius²                              (imaps.c:519)
    if scale < 1:  importance_level[side] ± importance*(1 − scale)  (imaps.c:521-525, ±: 429-438)
```
Quadratic falloff to zero at `importance_radius`. Callers: keysite create/destroy/capture/in-use transitions (eech ks_creat.c:241, ks_dstry.c:337, keysite.c:551/1334/1355, ks_pack.c:351/391/417, faction.c:390/622/1029). PSD side files may also seed importance via an "IMPORTANCE" layer (eech popread.c:406-410).

**Normalisation.** `normalise_importance_imaps` copies `importance_level[side]` into the float scratch and min-max normalises to bytes 0–255 per side (eech imaps.c:536-572; `normalise_inlfuence_map` [sic] eech imaps.c:189-242: skip if max==min, else `255*(v−min)/(max−min)`).

**Cadence.** Registered every **120 s** (`2.0 * ONE_MINUTE`), start anchor **20 s** (eech highlevl.c:272); also once at AI start (highlevl.c:203).

### SECTOR-F11 — IMAP_BASE_DISTANCE layer

**Raw rebuild.** `update_imap_distance_to_friendly_base (side)` zeroes `distance_to_friendly_base[side]` for all sectors (eech imaps.c:708-720 — note loops use `<` MAX, so the last row/column is never cleared), then for every alive+in-use keysite of the force (eech imaps.c:728-741) runs `update_keysite_distance_to_friendly_base` (eech imaps.c:618-688):

```
sector_radius = max(1, int(air_coverage_radius / SECTOR_SIDE_LENGTH))   (imaps.c:642-648)
scale = 1 − (x² + z²)/sector_radius²   if positive                       (imaps.c:677-681)
distance_to_friendly_base[side] = max(current, scale)                    (imaps.c:584-612, max at 602)
```
So despite the name it is a 0..1 **proximity-to-own-airpower** field (1 at a base, 0 beyond `air_coverage_radius`; only AIRBASE 400 km, FARP/carrier 100 km contribute — others have 0 radius, §2.5). Max-combined, not summed.

**Triggers.** Full per-side rebuild on keysite destruction (eech ks_dstry.c:339), capture (eech keysite.c:1345), client keysite updates (eech ks_pack.c:372, 425); if imaps initialised, rebuild immediately re-normalises (eech imaps.c:743-746).

**Normalisation.** `normalise_base_distance_imaps` min-max per side (eech imaps.c:753-789); registered every **120 s**, anchor **40 s** (eech highlevl.c:274); once at start (highlevl.c:205).

### SECTOR-F12 — IMAP_AIR_DEFENCE layer

**Raw accumulation.** On every sector link/unlink of a live vehicle (`INT_TYPE_IDENTIFY_VEHICLE`; aircraft do **not** contribute), `add_mobile_values_to_sector` / `remove_mobile_values_from_sector` (eech sector.c:238-292) call `update_imap_surface_to_air_defence_level (en, sector, TRUE/FALSE)` (eech imaps.c:844-912):

```
value = FLOAT_TYPE_POTENTIAL_SURFACE_TO_AIR_THREAT  (imaps.c:864; vehicle db)
radius = FLOAT_TYPE_AIR_SCAN_RANGE * 10.0 / SECTOR_SIDE_LENGTH   (imaps.c:870)   <-- 10x scan range
sector_radius = max(1, int(radius)); quadratic falloff  scale = 1 − (x²+z²)/sr²  (imaps.c:872-907)
surface_to_air_defence_level[side] ± value*scale                                  (imaps.c:801-838)
```

**Normalisation.** `normalise_air_defence_imaps` (eech imaps.c:918-954); every **120 s**, anchor **60 s** (eech highlevl.c:276); once at start (207).

**Aggregate helper:** `get_local_sector_entity_enemy_surface_to_air_defence_level` sums the raw per-side values of all sides except the querying one (eech sector.c:133-172).

### SECTOR-F13 — IMAP_SURFACE_DEFENCE layer

Identical structure to F12 with `FLOAT_TYPE_POTENTIAL_SURFACE_TO_SURFACE_THREAT` and `FLOAT_TYPE_SURFACE_SCAN_RANGE * 10.0` (eech imaps.c:1009-1077, radius 1035; accumulator 966-1003). Normalised by `normalise_surface_defence_imaps` (eech imaps.c:1083-1119); every **120 s**, anchor **80 s** (eech highlevl.c:278); once at start (209). Enemy-sum helper eech sector.c:178-186.

### SECTOR-F14 — Update scheduling / stagger semantics

`add_high_level_ai_function (fn, frequency, start_time)` (eech highlevl.c:346-369): frequency in seconds, must divide 24 h exactly (`ASSERT fmod(24h, frequency)==0`, highlevl.c:359); offset computed from campaign elapsed time so functions fire at fixed wall-clock anchors (highlevl.c:361-368). Registered set (server only, eech highlevl.c:181-287):

| Function | Period | Anchor |
|---|---|---|
| normalise_importance_imaps | 120 s | 20 s | eech highlevl.c:272 |
| normalise_base_distance_imaps | 120 s | 40 s | eech highlevl.c:274 |
| normalise_air_defence_imaps | 120 s | 60 s | eech highlevl.c:276 |
| normalise_surface_defence_imaps | 120 s | 80 s | eech highlevl.c:278 |
| update_client_server_sector_fog_of_war | 30 s | 8 s | eech highlevl.c:280 |
| update_client_server_sector_side_count | 60 s | 15 s | eech highlevl.c:282 |

(The 12 task-generation functions are registered in the same block, eech highlevl.c:218-269 — campaign cadences 2–30 min; skirmish variants differ.) All removed at `stop_high_level_ai` (eech highlevl.c:293-340).

**Important:** raw sector fields update **event-driven**; the 120 s jobs only re-normalise the byte imaps that task scoring reads. There is no decay on imap layers — contributions are explicitly removed on unlink/destroy (asymmetric float add/subtract with `ASSERT value > 0` before subtract, e.g. eech imaps.c:316, 435, 825, 990).

### SECTOR-F15 — imap consumption in task-generation scoring

`get_imap_value` terms actually live (commented-out terms noted):

| Task | Formula terms (weights) | Source |
|---|---|---|
| Advance/retreat: group pick | `1*(1 − BASE_DISTANCE[enemy])` + `1*BASE_DISTANCE[own]` | eech highlevl.c:457-460 |
| Advance/retreat: destination node | `2*BASE_DISTANCE[enemy]` (move toward enemy bases); node must not be occupied by own side and link `breaks==0` | eech highlevl.c:514-532 |
| BAI | `2*(1 − AIR_DEFENCE[enemy])` + `3*BASE_DISTANCE[own]` + `2*side_ratio(own)`; IMPORTANCE & SURFACE_DEFENCE terms disabled (comments 669, 675); max_rating 7.0 | eech highlevl.c:658-683 |
| CAS | `1*(1 − AIR_DEFENCE[enemy])` + `3*BASE_DISTANCE[own]`; IMPORTANCE & SURFACE_DEFENCE disabled (909, 915) | eech highlevl.c:898-918 |
| Keysite strike | `1*(1 − AIR_DEFENCE[enemy])` + `4*BASE_DISTANCE[own]`; IMPORTANCE disabled (1113) | eech highlevl.c:1116-1119 |
| OCA strike | `1*(1 − AIR_DEFENCE[enemy])` + `4*BASE_DISTANCE[own]` | eech highlevl.c:1373-1376 |
| OCA sweep | `1*(1 − AIR_DEFENCE[enemy])` + `4*BASE_DISTANCE[own]` | eech highlevl.c:1560-1563 |
| Troop insertion | `1*(1 − AIR_DEFENCE[enemy])` + `3*BASE_DISTANCE[own]`; IMPORTANCE disabled (1752) | eech highlevl.c:1755-1758 |
| SEAD | `4*BASE_DISTANCE[own]`; AIR_DEFENCE & IMPORTANCE terms disabled (2001-2004) | eech highlevl.c:2007 |
| Fixed-wing transfer (destination keysite) | `4*BASE_DISTANCE[side]`; other three sampled but disabled (2249-2255) | eech highlevl.c:2238-2258 |
| Helicopter transfer | `4*BASE_DISTANCE[side]`; others disabled (2469-2475) | eech highlevl.c:2458-2478 |
| Group reaction rating | `(1 − AIR_DEFENCE)` + `SURFACE_DEFENCE` + `2*BASE_DISTANCE` (all own side) | eech reaction.c:761-776 |
| Map overlay (UI) | draws BASE_DISTANCE layer | eech ui_menu/ingame/common/map.c:4346 |

Note IMAP_IMPORTANCE is normalised on schedule but **every live consumer term is commented out** — it only feeds debug output and the samples logged at eech highlevl.c:691/931. IMAP_SURFACE_DEFENCE's only live consumer is reaction.c:773.

### SECTOR-F16 — Frontline computation

**Algorithm** (`create_frontline (force)`, eech ai_fline.c:125-171):
1. Unlink the force's previous `LIST_TYPE_SECTOR_FRONTLINE` children (144).
2. For every sector: `check_sector_frontline (side, x, z)` (eech ai_fline.c:177-218) — sector qualifies iff its **static** `INT_TYPE_SIDE` equals the force side (191-195) and any of its up-to-8 neighbours (3×3 box, clipped) has a different side (201-215).
3. Qualifying sectors get `INT_TYPE_FRONTLINE_FLAG = FRONTLINE_SECTOR_PRIMARY` (163) and are appended to the scratch array + relinked under the force (`add_sector_to_frontline`, eech ai_fline.c:224-244; also re-asserts sector side, 233).
4. `parse_frontline_arrangements` (eech ai_fline.c:250-377) orders the list into a chain: counts 4-neighbour adjacencies among frontline sectors (269-292), starts from the sector with the fewest adjacencies (298-312), then repeatedly appends an uninserted 4-adjacent sector (332-376), producing an ordered contour in the force's child list.

**Trigger/cadence.** Called **once per force at campaign load** (eech ai/faction/parser.c:1369, inside the faction/attitude tag) and on MP client campaign receive (eech comms/comm_man.c:2335). `recreate_frontline (x, z)` exists (eech ai_fline.c:383-398) but has **no callers** anywhere in the tree — the frontline is never recomputed during play. (parsgen.c:1486 has the call commented out.)

**Outputs consumed.** The ordered `LIST_TYPE_SECTOR_FRONTLINE` list and `INT_TYPE_FRONTLINE_FLAG` have **no readers** outside ai_fline.c itself (verified by global search) — see Open questions. The *practical* frontline consumer chain is SECTOR-F17 (placement at load) plus the road-node `side_occupying` dance during advance/retreat (eech gp_msgs.c:475-944).

### SECTOR-F17 — Frontline force placement (campaign start)

`place_frontline_forces (force, force_size)` (eech ai/faction/faction.c, body ~1330-1660; triggered by campaign-file tag `FILE_TAG_FRONTLINE_FORCES` with value > 0, eech parser.c:1426-1442):

1. For every road node, record the **static side** of the sector containing it (eech faction.c:1376-1381).
2. **Primary** nodes: own-side node with at least one road link into an enemy-side node (eech faction.c:1387-1420).
3. **Secondary** nodes: own-side unmarked nodes directly linked to a primary node (eech faction.c:1426-1464).
4. **Artillery** nodes: own-side unmarked nodes directly linked to a secondary node (eech faction.c:1470-1508).
5. Placement at each marked node (must be inside adjusted map + population area): group size `int(safe_radius/4 + sfrand1()*2)` bounded [1, force_size] for primary/secondary (eech faction.c:1540-1542, 1579-1581), `int(safe_radius/5)` for artillery (1640-1644); artillery alternates MLRS/tube formations via `mlrs_flag` (1624-1633); group types `ENTITY_SUB_TYPE_GROUP_PRIMARY_FRONTLINE` / `SECONDARY_FRONTLINE` / artillery component group (1550, 1589, 1650); each group records its `INT_TYPE_ROUTE_NODE` and marks `road_nodes[node].side_occupying = side` (1554-1556 etc.). Requires a friendly keysite within 1 km search start (`get_closest_keysite ... 1.0*KILOMETRE`, 1546).

Note `road_nodes[node].safe_radius` is **hardcoded to 28** at load, overriding the file value (eech ai_route.c:409-414), so primary/secondary groups are `bound(7±2, 1, force_size)` and artillery 5 vehicles.

### SECTOR-F18 — Road/sector routing data (`ai_route.c`)

- Loading: node graph `ROADS.dat` (node id, safe radius [discarded, see F17], link list with integer costs — eech ai_route.c:331-538), node positions `ROADS.nde` (eech 551-629), per-link waypoint polylines with `path_type` `ROADS.wp` (eech 644-781; endpoints spliced in at 731-734; positions clamped to map 744-746).
- Sector classification constants `ALLIED_SECTOR` 0 / `FRONT_LINE_SECTOR` 1 / `ENEMY_SECTOR` 2 defined (eech ai_route.c:89-93) but unused in this file.
- `get_road_link_data` / `get_road_sub_route`: linear search for the link record between two nodes (order-normalised) — eech ai_route.c:824-892, 898-1063.
- **Bridge breaks:** `set_road_link_breaks (node1, node2, count)` stores destroyed-bridge count symmetrically on both directions (max 32, eech ai_route.c:1069-1117); `get_road_link_breaks` returns it, −1 if not linked (eech 1123-1162). Advance is blocked unless `breaks == 0` (eech highlevl.c:516).
- `clear_road_route_data` resets per-node `visited` for path search (eech ai_route.c:787-814). `initialise_road_safe_radius` is fully commented out (eech ai_route.c:1169-1233).
- Node occupancy state machine during advance/retreat (`side_occupying` transfer between current/advance/retreat nodes) lives in eech entity/special/group/gp_msgs.c:475-944.

### SECTOR-F19 — AI sector exposure (dead code)

`initialise_ai_sectors` is a no-op: the call to `initialise_ai_sector_exposure` is commented out (eech ai/ai_misc/ai_sect.c:87-91). The dead function would have computed a 0–255 terrain-roughness "exposure" per sector from the four underlying terrain sub-sectors (average height deltas ×2, bounded 0-255) into `INT_TYPE_EXPOSURE_LEVEL` (eech ai_sect.c:97-176; terrain sub-sector grid is 2× the sector grid, 115-118). Do not port.

---

## 4. Interactions

- **Keysites → sectors:** every keysite lifecycle event rewrites `sector_side` (F4), `importance_level` (F10) and rebuilds `distance_to_friendly_base` (F11). Keysite capture is therefore the sole driver of dynamic territorial control.
- **Vehicles → sectors:** sector crossing adds/removes S-A and S-S threat (F12/F13) and stamps FOW (F6). Aircraft stamp FOW but contribute no threat imap.
- **Sectors → task generation:** all 12 `create_*_tasks` functions score candidates from normalised imaps (F15), FOW thresholds (F9), per-sector task counts (F2), and `get_local_sector_side_ratio` (F4). Ratings feed `quicksort_entity_list` target ordering (eech highlevl.c:486).
- **Sectors → ground war:** advance/retreat picks road-node destinations by BASE_DISTANCE imap and node occupancy/breaks (eech highlevl.c:505-543); group advance messages update node occupancy (gp_msgs.c).
- **Sectors → campaign status/win criteria:** `INT_TYPE_FORCE_SECTOR_COUNT` (F5) feeds campaign UI ca_stat.c:724-726 and captured/lost-sector campaign criteria (parser.c:1152-1153); `CAMPAIGN_CRITERIA_SECTOR_REACHED` uses x/z sector tags (parser.c:1086-1098).
- **Sectors → UI/map:** FOW shading and keysite visibility (map.c:1396, 4273-4295), BASE_DISTANCE overlay (map.c:4346), grid numbering from `SECTOR_SIDE_LENGTH` (map.c:4748-4844), TSD avionics grid (co_tsd.c:1932+), tacview export filter (tacview.c:640).
- **Sectors → speech:** force-entered-sector notifications trigger air-defence/keysite sighted speech stubs (eech sector.c:691-742 — bodies are empty comment blocks).
- **Frontline → initial ground OOB:** F16's static-side adjacency logic (re-expressed over road nodes) decides where primary/secondary/artillery groups spawn (F17).
- **Client/server:** sectors are local-only entities; FOW decay and side counts are server-computed and broadcast as comms messages (F5, F7); FOW grants happen locally on each machine via the link-child response.

---

## 5. Port mapping

(Port state taken from the supplied summary only: DCS port implements `imap` (4 layers, 120 s update, 20 s stagger), `fog_of_war` (per-base per-side, 30 s decay tick, radii 20/10/3 km flagged VERIFY), `frontline` (base-distance proxy, 140 km threshold, bases-as-sectors); sectors grid and road/sector routing not ported.)

| Feature | Status | Note |
|---|---|---|
| SECTOR-F1 grid creation | NOT PORTED | Port uses bases-as-sectors; EECH is a uniform power-of-two grid with per-cell entities. |
| SECTOR-F2 membership/tallest/task lists | NOT PORTED | No sector entities; per-sector task-count caps have no direct equivalent. |
| SECTOR-F3 static painted sides | NOT PORTED | EECH's frontline and initial placement depend on this immutable paint layer. |
| SECTOR-F4 dynamic control (`sector_side`) | UNKNOWN | Not mentioned in port summary; EECH derives control purely from keysite `sector_side_max_value` fields with 1/d² falloff. |
| SECTOR-F5 sector side count | NOT PORTED | Needs a grid (or proxy count over bases). |
| SECTOR-F6 FOW grant | PARTIAL (fog_of_war) | Port grants per-base; EECH stamps a per-sector linear-falloff footprint of the full 4 h timer, radius = 2× unit `recon_radius`. |
| SECTOR-F7 FOW decay 30 s | PORTED (fog_of_war) | 30 s tick matches `FOG_OF_WAR_DECAY_RATE` 30.0 exactly; verify the port also decrements 30 s of a 14 400 s budget and applies the friendly-control full-visibility override. |
| SECTOR-F8 recon radii | PROXY — port values REFUTED as EECH constants | 20/10/3 km do not exist in EECH; real data-driven values §3 F8 (fighters 10 km→20 km effective, attack helis 5 km→10 km, transports 3 km→6 km, ground 0.5–2 km typical →1–4 km, recon/AD/ships up to 16 km). |
| SECTOR-F9 FOW thresholds | UNKNOWN | Port summary doesn't say whether task gating uses 0.5/0.25/0.2 × max fractions. |
| SECTOR-F10 IMAP_IMPORTANCE | PARTIAL (imap) | Layer count (4) and 120 s cadence match; EECH's live scoring weight for this layer is zero (all terms commented out). |
| SECTOR-F11 IMAP_BASE_DISTANCE | PARTIAL (imap) | Port bases-as-sectors is structurally close since only airbase/FARP/carrier `air_coverage_radius` contributes; EECH max-combines quadratic falloff and rebuilds on keysite events. |
| SECTOR-F12 IMAP_AIR_DEFENCE | PARTIAL (imap) | Verify port uses vehicle-only contributors, `air_scan_range × 10` radius, quadratic falloff, event-driven add/remove. |
| SECTOR-F13 IMAP_SURFACE_DEFENCE | PARTIAL (imap) | Same; note only consumer in EECH is the reaction rating. |
| SECTOR-F14 normalisation/stagger | PORTED (imap) | 120 s with staggering matches (EECH anchors 20/40/60/80 s; port 20 s stagger equivalent in spirit); ensure min-max normalisation and the max==min skip. |
| SECTOR-F15 imap task weights | UNKNOWN | Weights (2/3/4×, disabled terms) live in the task-gen spec's scoring; verify against this table. |
| SECTOR-F16 frontline algorithm | PROXY (frontline) | Port's 140 km base-distance threshold is an invention; EECH frontline = static-side 8-neighbour boundary sectors, computed once at load, never recomputed, and its list output is (apparently) never even read back. |
| SECTOR-F17 frontline force placement | UNKNOWN | Depends on road nodes (not ported); group sizes 7±2 / 5 from hardcoded safe_radius 28. |
| SECTOR-F18 road routing | NOT PORTED | Per port summary; bridge-break blocking of advances is lost with it. |
| SECTOR-F19 exposure | NOT PORTED | Dead in EECH too — correct to omit. |

**Most consequential gaps:** (1) FOW radii are per-unit-type data (×2, linear falloff), not per-category constants — the flat 3 km ground radius over-scouts infantry and under-scouts recon/AD units; (2) EECH's frontline is a static-paint boundary used only for initial placement — a dynamic 140 km base-distance frontline is a different mechanism, so advance/retreat behaviour (imap-driven node hopping with occupancy and bridge breaks) has no EECH-faithful substrate; (3) the friendly-control FOW override (controlled territory always visible) and the event-driven (not periodic) imap accumulation are easy to miss.

---

## 6. Open questions

1. `initialise_node_awareness ()` is called at campaign load (eech parser.c:479) but **no definition exists anywhere in the tree** (global case-insensitive search). Either the source drop is incomplete or it resolves via some macro not found; the node `side_aware` field is otherwise only referenced in commented-out code (faction.c:1447, 1491; ai_misc.c:554).
2. `parse_frontline_arrangements` early-out is `if (number_of_frontline_arrangement_slots_used <- 0) return;` (eech ai_fline.c:263) — parses as `< -0`, i.e. never true. With 0 slots the function reads `frontline_sectors_arrangements[0]` uninitialised and inserts its (garbage/NULL) sector (298-326). Presumably never hit because every campaign has a frontline; do not replicate.
3. `INT_TYPE_FRONTLINE_FLAG` is written on sector entities (eech ai_fline.c:163) but `ENTITY_TYPE_SECTOR` overloads no handler for it (eech sc_int.c:276-308) and **nothing reads it** — behaviour of the unoverloaded set path (no-op vs fatal) unverified.
4. The force's ordered `LIST_TYPE_SECTOR_FRONTLINE` list has no consumers found outside ai_fline.c. Is the ordered contour vestigial (an earlier EE-series feature), or consumed via some generic list walk not matched by search?
5. `update_imap_distance_to_friendly_base` clears with `z < MAX_MAP_Z_SECTOR` / `x < MAX_MAP_X_SECTOR` (eech imaps.c:708-710) — the top row/column never resets, so stale base-proximity can persist there after a keysite loss. Bug or intentional? (Normalisation still rescales it.)
6. `get_local_sector_side_ratio` asserts blue+red influence > 0 in every queried sector (eech sector.c:318); this holds only because F4's falloff spans the entire map from every keysite. A port with local falloff must guard the division.
7. FOW grant uses `get_approx_3d_range` from the *sector centre at y=0* to the unit (eech sector.c:451-486) — mild altitude coupling (high-flying aircraft stamp slightly less at the fringe). Worth replicating? (Likely negligible.)
8. Exact semantics of `add_update_function (function, frequency, offset)` (scheduler internals) were not traced; cadence/anchor values above are as registered.
9. Aircraft carriers (ANCHORAGE) move; whether their `sector_side`/importance contributions are re-anchored when the carrier changes sector was not traced in this pass (contributions are keyed to position at add time, eech imaps.c:365-368).
