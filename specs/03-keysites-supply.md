# EECH Spec 03 — Keysites & Supply

Sources:
- `aphavoc/source/entity/special/keysite/ks_dbase.c` / `ks_dbase.h` (per-type database)
- `aphavoc/source/entity/special/keysite/ks_updt.c` (server update tick)
- `aphavoc/source/entity/special/keysite/keysite.c` / `keysite.h` (cargo, strength, capture, destroy, repair)
- `aphavoc/source/entity/special/keysite/ks_creat.c` (creation defaults)
- `aphavoc/source/entity/special/keysite/ks_dstry.c` (kill handler)
- `aphavoc/source/entity/special/keysite/ks_msgs.c` (cargo pick-up/drop-off messages)
- `aphavoc/source/entity/special/keysite/ks_float.c` / `ks_int.c` (accessors incl. efficiency)
- `aphavoc/source/entity/system/en_types/en_suply.c` / `en_suply.h` (supply constants, rearm/refuel time formulas)
- `aphavoc/source/entity/system/en_types/en_state.h`, `en_sbtyp.h` (state / sub-type enums)
- `aphavoc/source/entity/mobile/mb_msgs.c` (cargo delivery, landed rearm/refuel, troop-insert capture, repair waypoint)
- `aphavoc/source/entity/special/group/group.c` (group resupply from keysites)
- `aphavoc/source/entity/special/force/fc_msgs.c` (supply task creation, campaign objective check)
- `aphavoc/source/ai/taskgen/assign.c`, `ai/highlevl/highlevl.c`, `ai/highlevl/reaction.c`, `ai/highlevl/imaps.c` (consumers of the flag table)
- `aphavoc/source/wutcfg.c`, `gwutcfg.c` (warzone data override of the database)
- `aphavoc/source/entity/mobile/cargo/cargo.h` (crate sizes)

## 1. Overview

Keysites are the fixed strategic installations of the EECH dynamic campaign: airbases, carriers, factories, FARPs, military bases, ports, power stations, oil refineries and radio transmitters. Each keysite is an entity that aggregates a group of fixed buildings; the sum of building "importance" values gives the keysite a strength, and `strength / maximum_strength` is its **efficiency**. Keysites produce or consume **ammo** and **fuel** supply on a 1-minute tick; producers (factory, refinery, port) accumulate stock that is physically represented as cargo-crate entities, and consumers (airbase, FARP, military base, power station) drain stock and, when low, trigger force-level air supply missions that fly a crate from the nearest producer and reset the destination's supply level to 100. Aircraft groups rearm/refuel out of their keysite's stock; the stock level scales how long rearm/refuel takes. Damaged repairable keysites become UNUSABLE below minimum efficiency, spawn REPAIR missions, and rebuild one building at a time on a 10/20-minute timer once a repair unit arrives. Keysites are captured by enemy troop-insertion tasks (probabilistically, weighted by efficiency and troop losses), which flips side, buildings, influence maps and regen queues, and re-checks campaign victory conditions. All per-type behaviour flags live in a single 9-row database in `ks_dbase.c`, overridable per-warzone via WUT config files.

Everything below is server-side (`COMMS_MODEL_SERVER`) campaign logic unless noted.

## 2. Data model

### 2.1 Keysite sub-type enum — `eech en_sbtyp.h:406-414`

```
ENTITY_SUB_TYPE_KEYSITE_AIRBASE            (406)
ENTITY_SUB_TYPE_KEYSITE_ANCHORAGE          (407)   // "Carrier"
ENTITY_SUB_TYPE_KEYSITE_FACTORY            (408)
ENTITY_SUB_TYPE_KEYSITE_FARP               (409)
ENTITY_SUB_TYPE_KEYSITE_MILITARY_BASE      (410)
ENTITY_SUB_TYPE_KEYSITE_PORT               (411)
ENTITY_SUB_TYPE_KEYSITE_POWER_STATION      (412)
ENTITY_SUB_TYPE_KEYSITE_OIL_REFINERY       (413)
ENTITY_SUB_TYPE_KEYSITE_RADIO_TRANSMITTER  (414)
```

### 2.2 `keysite_data` (per-type database row) — `eech ks_dbase.h:67-108`

| Field | Type | Meaning |
|---|---|---|
| `full_name`, `short_name` | `char*` | display names |
| `default_supply_usage` | `supply_type` | signed per-minute ammo/fuel delta (see F5); air/ground + air/air fields present but 0 for all types |
| `importance` | float | strategic weight (imap painting, targeting) |
| `minimum_efficiency` | float | efficiency floor below which keysite is unusable/killed |
| `importance_radius` | float | radius painted into IMAP_IMPORTANCE (`eech imaps.c:486`) |
| `air_coverage_radius` | float | radius painted into air-coverage imap (`eech imaps.c:642`) |
| `recon_distance` | float | stand-off distance for recon tasks against this type |
| `sector_side_max_value` | float | cap on sector-side influence contribution (exposed via `FLOAT_TYPE_KEYSITE_SECTOR_SIDE_VALUE`, `eech ks_float.c:336`) |
| `map_layer_type`, `map_icon`, `align_with_terrain`, `unique_name`, `hidden_by_fog_of_war` | bitfields | map/UI presentation |
| `air_force_capacity` | 2 bits | NONE / SMALL / LARGE (`eech keysite.h:77-84`) |
| `report_ammo_level`, `report_fuel_level` | 1 bit | whether ammo/fuel level is reported in UI |
| `assign_task_count` | 2 bits | tasks assigned per assignment pass (`eech assign.c:218`) |
| `reserve_task_count` | 2 bits | non-critical tasks held in reserve (`eech assign.c:220`) |
| `requires_cap` | 1 bit | AI generates CAP over it (`eech reaction.c:243`) |
| `requires_barcap` | 1 bit | AI generates BARCAP (`eech reaction.c:257`) |
| `repairable` | 1 bit | can enter REPAIRING; non-repairable keysites are killed below min efficiency |
| `oca_target` | 1 bit | valid OCA (airbase-strike) target (`eech highlevl.c:1353,1540`, `reaction.c:455,897`) |
| `recon_target` | 1 bit | valid recon target |
| `ground_strike_target` | 1 bit | valid ground-strike target; also gates the *probabilistic* capture branch (`eech mb_msgs.c:2277`) |
| `ship_strike_target` | 1 bit | valid ship-strike target |
| `troop_insertion_target` | 1 bit | valid troop-insertion(capture) target (`eech highlevl.c:1728`); also switches campaign-objective test to "must own" vs "must destroy" (`eech fc_msgs.c:190`) |
| `campaign_objective` | 1 bit | counted as a campaign objective (`eech ks_int.c:344`, `setup.c:126`) |

### 2.3 Per-type database flag table — `eech ks_dbase.c:81-507`

Row source lines: Airbase 91-130, Carrier(Anchorage) 138-177, Factory 185-224, FARP 232-271, Military Base 279-318, Port 326-365, Power Station 373-412, Oil Refinery 420-459, Radio Transmitter 467-506. `KILOMETRE` = 1000 m (`eech constant.h:115`).

| Field | Airbase | Carrier | Factory | FARP | Military Base | Port | Power Station | Oil Refinery | Radio Transmitter |
|---|---|---|---|---|---|---|---|---|---|
| supply usage: ammo (%/min) | **-0.2** | 0.0 | **+1.0** | **-0.05** | **-0.2** | **+0.2** | 0.0 | 0.0 | 0.0 |
| supply usage: fuel (%/min) | **-0.4** | 0.0 | +0.0 | **-0.03** | **-0.2** | **+0.2** | **-0.5** | **+1.0** | 0.0 |
| importance | 1.0 | 1.0 | 0.5 | 0.4 | 0.8 | 0.2 | 0.3 | 0.4 | 0.5 |
| minimum efficiency | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 |
| importance radius (km) | 80 | 60 | 40 | 40 | 30 | 20 | 30 | 30 | 30 |
| air coverage radius (km) | 400 | 100 | 0 | 100 | 0 | 0 | 0 | 0 | 0 |
| recon distance (m) | 1000 | 280 | 300 | 320 | 450 | 700 | 400 | 800 | 250 |
| sector side max value | 80 | 50 | 20 | 40 | 30 | 20 | 0 | 20 | 30 |
| map layer | CONTROL_KEYSITES | CONTROL_SHIPS | CONTROL_KEYSITES | CONTROL_KEYSITES | CONTROL_KEYSITES | CONTROL_KEYSITES | CONTROL_KEYSITES | CONTROL_KEYSITES | CONTROL_KEYSITES |
| map icon | AIRBASE | CARRIER | BUILDING | FARP | BUILDING | BUILDING | POWER_STATION | OIL_REFINERY | RADIO_TRANSMITTER |
| align with terrain | F | F | F | T | F | F | F | F | F |
| unique name | T | T | F | F | F | F | F | F | F |
| hidden by fog of war | F | T | F | T | T | F | T | T | T |
| air force capacity | LARGE | SMALL | NONE | SMALL | NONE | NONE | NONE | NONE | NONE |
| report ammo level | T | T | T | T | T | T | F | F | F |
| report fuel level | T | T | F | T | T | T | T | T | F |
| task assign count | 3 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| task reserve count | 2 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| requires CAP | **T** | F | F | **T** | F | F | F | F | F |
| requires BARCAP | F | **T** | F | F | F | F | F | F | F |
| repairable | **T** | F | **T** | **T** | **T** | F | F | F | F |
| OCA target | **T** | **T** | F | F | F | F | F | F | F |
| recon target | **T** | **T** | F | **T** | **T** | F | **T** | **T** | **T** |
| ground strike target | **T** | F | **T** | **T** | **T** | **T** | **T** | **T** | **T** |
| ship strike target | F | **T** | F | F | F | F | F | F | F |
| troop insertion target | **T** | F | **T** | **T** | **T** | F | F | F | F |
| campaign objective | **T** | **T** | F | F | **T** | F | **T** | **T** | F |

Note the enforced invariant `repairable == troop_insertion_target` for every type (`eech ks_creat.c:191`, ASSERT: "currently required for the campaign to progress properly"). All rows satisfy it.

### 2.4 `KEYSITE` runtime struct — `eech keysite.h:90-145`

Key campaign fields: `sub_type`, `position`; list roots for unassigned/assigned/completed tasks, building groups, keysite groups (aircraft based there), division HQ, task dependents, **cargo**, regen queue, landing sites (`keysite.h:99-111`); floats `keysite_strength`, `keysite_maximum_strength`, `repair_timer`, `assist_timer`, `assign_timer`, `sleep` (`keysite.h:120-126`); `supplies` (`supply_type`, `keysite.h:128-129`); packed ints `alive`, `in_use`, `keysite_usable_state`, `side`, `ndb_frequency` (`keysite.h:134-142`).

### 2.5 Usable-state enum — `eech en_state.h:150-152`

`KEYSITE_STATE_USABLE`, `KEYSITE_STATE_UNUSABLE`, `KEYSITE_STATE_REPAIRING`.

### 2.6 `supply_type` — `eech en_suply.h:114-124`

`air_to_ground_ammo_supply_level`, `air_to_air_ammo_supply_level`, `ammo_supply_level`, `fuel_supply_level` (all floats, 0-100 scale for stocks; signed per-minute rates in the database). The two air/air-air fields are 0.0 in every database row and commented "ignore" (`eech ks_dbase.c:96-97` et al.).

### 2.7 Resupply source enum — `eech en_suply.h:99-108`

`RESUPPLY_SOURCE_NONE`, `RESUPPLY_SOURCE_KEYSITE`, `RESUPPLY_SOURCE_GROUP`. Assigned per group type in the group database (DATA-DRIVEN per group type, reader `eech gp_dbase.c:115-1140`): all fixed-wing/helicopter groups use KEYSITE; ground combat groups (tank/APC etc.) use GROUP; some (e.g. ships) use NONE.

### 2.8 Supply constants — `eech en_suply.h:67-93`

| Name | Value | Source |
|---|---|---|
| `MAX_REARMING_TIME_SCALING_FACTOR` | 5 | eech en_suply.h:67 |
| `MAX_REFUELING_TIME_SCALING_FACTOR` | 5 | eech en_suply.h:69 |
| `FUEL_SUPPLY_LEVEL_USAGE` | 10.0 | eech en_suply.h:71 — **dead: defined, never referenced** |
| `AMMO_SUPPLY_LEVEL_USAGE` | 10.0 | eech en_suply.h:73 — **dead: defined, never referenced** |
| `KEYSITE_MINIMUM_FUEL_SUPPLY_LEVEL` | 10.0 | eech en_suply.h:75 |
| `KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL` | 10.0 | eech en_suply.h:77 |
| `FUEL_USAGE_ACCELERATOR` | 1.0 | eech en_suply.h:79 |
| `FUEL_RESTOCK_ACCELERATOR` | 100.0 | eech en_suply.h:81 |
| `AMMO_USAGE_ACCELERATOR` | 1.0 | eech en_suply.h:83 |
| `AMMO_RESTOCK_ACCELERATOR` | 100.0 | eech en_suply.h:85 |
| `KEYSITE_SUPPLY_REQUEST_THRESHOLD` | 75.0 | eech en_suply.h:87 |
| `DEBUG_SUPPLY` | 0 | eech en_suply.h:93 |
| `CARGO_AMMO_SIZE` | 10 | eech cargo.h:89 |
| `CARGO_FUEL_SIZE` | 10 | eech cargo.h:91 |

### 2.9 Keysite timers — `eech keysite.h:67-71`

| Name | Value | Source |
|---|---|---|
| `DEFAULT_KEYSITE_ASSISTANCE_REQUEST_TIMER` | 60 s + sfrand1()·20 s | eech keysite.h:67 |
| `KEYSITE_TASK_ASSIGN_TIMER` | 3 · ONE_MINUTE (180 s) | eech keysite.h:69 |
| `KEYSITE_UPDATE_SLEEP_TIMER` | 1 · ONE_MINUTE (60 s) | eech keysite.h:71 |

`ONE_MINUTE` = seconds in a minute = 60 (`eech constant.h:163`).

## 3. Features

### KEYSITE-F1 — Keysite type database

Behaviour: a single static table `keysite_database[NUM_ENTITY_SUB_TYPE_KEYSITES]` (`eech ks_dbase.c:81-507`) defines every per-type constant and behaviour flag; see §2.3 for the full contents. Every consumer of keysite behaviour (task generation, capture, campaign objectives, imaps, supply) indexes this table by `sub_type`. `const` was deliberately removed from the definition so warzone mods can rewrite it at load time (comment `eech ks_dbase.c:79-80`; see KEYSITE-F18).

Cadence: static data, read everywhere.

### KEYSITE-F2 — Keysite creation defaults & invariants

Behaviour (`create_local`, `eech ks_creat.c:82-279`):
- Defaults: `alive = TRUE` (151), `keysite_usable_state = KEYSITE_STATE_USABLE` (153), `in_use = FALSE` (157), `side = ENTITY_SIDE_NEUTRAL` (160), `ammo_supply_level = 0.0`, `fuel_supply_level = 0.0` (162-164). Warzone attributes then overwrite these (176) — actual starting side/in_use/supply levels are DATA-DRIVEN (warzone entity data, applied via `set_local_entity_attributes`, `eech ks_creat.c:176`).
- Randomised initial timers to de-phase updates: `assign_timer = frand1()·180 s`, `sleep = frand1()·60 s` (`eech ks_creat.c:166-168`).
- Mandatory asserts: side ≠ neutral (184), valid sub-type (186), `minimum_efficiency < 1.0` (188), `repairable == troop_insertion_target` (191).
- Initial cargo crates materialised from supply levels (199-201; see F6).
- NDB frequency `100 + rand16() % 1900` only for airbase/anchorage/FARP/radio transmitter (203-205).
- Linked into force keysite list, sector list, update list; sector keysite count incremented (229-235); if `in_use`, paints sector-side, importance and base-distance imaps (237-244).
- Creates an empty `ENTITY_SUB_TYPE_GROUP_BUILDINGS` group as the container for site buildings (254-262).

| Constant | Value | Source |
|---|---|---|
| initial assign timer | frand1()·180 s | eech ks_creat.c:166 |
| initial sleep timer | frand1()·60 s | eech ks_creat.c:168 |
| NDB frequency | 100 + rand16()%1900 | eech ks_creat.c:205 |

### KEYSITE-F3 — Strength & efficiency model

Behaviour: each fixed building with `FLOAT_TYPE_FIXED_OBJECT_IMPORTANCE > 0` contributes its importance to the owning keysite. (Per-building importance values are DATA-DRIVEN — object/warzone data, read via `get_local_entity_float_value(..., FLOAT_TYPE_FIXED_OBJECT_IMPORTANCE)`, `eech keysite.c:669`.)

- Add (world build): `strength += value; maximum_strength += value` (`eech keysite.c:653-691`, adds at 675-677).
- Building destroyed: `strength -= value` only, maximum kept (`eech keysite.c:739-848`, subtract at 776-778). Also: any task with this keysite as objective is re-assessed for completion (792-810).
- Building repaired: `strength += value` (`restore_local_entity_importance_to_keysite`, `eech keysite.c:697-733`, add at 719).

Formula — efficiency (`FLOAT_TYPE_EFFICIENCY`, `eech ks_float.c:260-275`):

```
efficiency = keysite_strength / keysite_maximum_strength      (if maximum > 0)
           = 1.0                                              (if maximum == 0)
```

`FLOAT_TYPE_MINIMUM_EFFICIENCY` returns `keysite_database[sub_type].minimum_efficiency` (= 0.3 for all types) (`eech ks_float.c:285-291`).

Trigger/cadence: event-driven on building create/destroy/restore.

### KEYSITE-F4 — Server update cadence

Behaviour (`update_server`, `eech ks_updt.c:82-223`; registered as the keysite server update fn at 229-232). Runs every frame for each alive keysite; dead (`!raw->alive`) keysites return immediately (95-98).

- `assist_timer` counts down to 0 (100-105) — cooldown for under-attack assistance requests (see F15).
- `assign_timer` counts down; on expiry, if `in_use`, runs `assign_keysite_tasks` for TASK_CATEGORY_RECON, STRIKE and SUPPORT (107-116), then resets to `KEYSITE_TASK_ASSIGN_TIMER` (180 s); **the interval is doubled (360 s) if the keysite is not in `KEYSITE_STATE_USABLE`** (118-123).
- `sleep` counts down; on expiry, resets to `KEYSITE_UPDATE_SLEEP_TIMER` (60 s) and runs the supply tick (126-163; see F5).
- Repair handling every frame (169-222; see F10).

| Constant | Value | Source |
|---|---|---|
| task assign interval | 180 s (×2 if not USABLE) | eech ks_updt.c:118-123, keysite.h:69 |
| supply tick interval | 60 s | eech ks_updt.c:130, keysite.h:71 |

### KEYSITE-F5 — Supply production/consumption tick

Behaviour (inside the 60 s sleep expiry, `eech ks_updt.c:136-146`):

```
ammo_supply_level += AMMO_USAGE_ACCELERATOR (1.0) * database[sub_type].default_supply_usage.ammo_supply_level
fuel_supply_level += FUEL_USAGE_ACCELERATOR (1.0) * database[sub_type].default_supply_usage.fuel_supply_level
update_keysite_cargo (ammo level, CARGO_AMMO, CARGO_AMMO_SIZE=10)
update_keysite_cargo (fuel level, CARGO_FUEL, CARGO_FUEL_SIZE=10)
ammo_supply_level = bound (ammo, KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL=10.0, 100.0)
fuel_supply_level = bound (fuel, KEYSITE_MINIMUM_FUEL_SUPPLY_LEVEL=10.0, 100.0)
```

So per-type rates in §2.3 are **percentage points per minute**, negative = consumer (airbase −0.2 ammo / −0.4 fuel; FARP −0.05 / −0.03; military base −0.2 / −0.2; power station −0.5 fuel), positive = producer (factory +1.0 ammo; refinery +1.0 fuel; port +0.2 / +0.2), zero = inert (carrier, radio transmitter). Levels can never drop below 10.0 or exceed 100.0 — **consumption alone never empties a keysite**; only crate pick-up subtracts below the tick floor (F8).

Trigger/cadence: every 60 s per keysite, de-phased by random initial sleep.

### KEYSITE-F6 — Physical cargo crates & low-supply request

Behaviour (`update_keysite_cargo`, `eech keysite.c:337-501`):
- No-op while game is initialising, or if keysite is not alive or not in use (361-373).
- Crates are real `ENTITY_TYPE_CARGO` entities laid out in a row at the keysite's supply position (375-385), one crate per `cargo_size` (=10) points of supply: surplus crates beyond `level/10` are destroyed (391-432), missing ones are created while `temp_cargo_level > cargo_size` (438-468). Crates inherit the keysite's side (458).
- If instead `cargo_level <= KEYSITE_SUPPLY_REQUEST_THRESHOLD` (75.0) **and** the keysite's database rate for that commodity is negative (i.e. it is a consumer of it), it notifies its force with `ENTITY_MESSAGE_FORCE_LOW_ON_SUPPLIES` (469-500; ammo check 479, fuel check 490). Producers never request resupply.

| Constant | Value | Source |
|---|---|---|
| crate size (ammo/fuel) | 10 supply points | eech cargo.h:89,91 |
| resupply request threshold | ≤ 75.0 | eech keysite.c:469, en_suply.h:87 |
| request condition | database rate < 0 for that commodity | eech keysite.c:479,490 |

### KEYSITE-F7 — Force supply-task distribution (the logistics chain)

Behaviour (`response_to_force_low_on_supplies`, `eech fc_msgs.c:672-892`; registered at 1366):
- Server-only; ignores requests while uninitialised (697-701).
- De-duplication: if the requester already has an `ENTITY_SUB_TYPE_TASK_SUPPLY` task pending for the same cargo sub-type (`FLOAT_TYPE_TASK_USER_DATA == sub_type`), return (722-743).
- Supplier selection (753-803), all via `get_closest_keysite(type, side, pos, min_range = 10 km, …, outside_of_range=TRUE, …)`:
  - AMMO: nearest friendly FACTORY; if none, nearest OIL_REFINERY; then compare with nearest AIRBASE and take whichever is closer (756-778).
  - FUEL: nearest friendly OIL_REFINERY; if none, FACTORY; then compare with nearest AIRBASE, take closer (780-803).
  - A commented-out 75 km maximum-range rejection exists (dead code, `eech fc_msgs.c:832-844`).
- Finds an actual crate entity of the right sub-type in the supplier's cargo list (812-826); if found, creates `create_supply_task (sender, factory, cargo, MOVEMENT_TYPE_AIR, task_database[TASK_SUPPLY].task_priority, …)` (846-848). Movement type is always AIR (846). If no supplier or no crate, nothing happens (silent failure) (866-889).
- Requesters are keysites (F6) **and** ground groups with `RESUPPLY_SOURCE_GROUP` whose ammo or fuel < 100 (`assess_group_supplies`, `eech group.c:635-668`).

Trigger/cadence: message-driven (on each low-supply notification, subject to de-dup).

### KEYSITE-F8 — Crate pick-up / drop-off accounting

Behaviour:
- **Pick-up** (helicopter reaches pick-up waypoint; keysite handler `response_to_waypoint_pick_up_reached`, `eech ks_msgs.c:251-296`): source keysite's stock is debited one crate — `ammo −= CARGO_AMMO_SIZE (10)` or `fuel −= CARGO_FUEL_SIZE (10)` (281-292). The crate rides on the mover's MOVEMENT_DEPENDENT list.
- **Drop-off at a keysite** (mover reaches drop-off waypoint, `eech mb_msgs.c:906-1090`): crate is moved from the mover's list into the requester keysite's CARGO list (940-962) and the keysite is notified; the keysite handler (`response_to_waypoint_drop_off_reached`, `eech ks_msgs.c:200-245`) then sets the delivered commodity's supply level to **100.0 flat** (230, 238) — one crate delivery fully restocks a keysite.
- **Drop-off to a group** (requester is a ground group, `eech mb_msgs.c:964-1018`): `level += KEYSITE_MINIMUM_*_SUPPLY_LEVEL (10) * *_RESTOCK_ACCELERATOR (100)` bounded to [0, 100] (980-1001) — i.e. also a full restock (10 × 100 = 1000, clamped to 100).
- On supply-task completion the keysite logs its new levels (`eech ks_msgs.c:164-194`; the debug_log at 175 is active, not compiled out).

### KEYSITE-F9 — Aircraft group resupply from keysite stock & rearm/refuel timing

Behaviour:
- **Per-member landing** (`eech mb_msgs.c:1387-1458`, inside landing-waypoint handler): for AI members of a group with `RESUPPLY_SOURCE_KEYSITE`: group fuel stock `−= FLOAT_TYPE_FUEL_ECONOMY · FUEL_USAGE_ACCELERATOR (1.0)` (1404), member fuel reset to default weight (1410); weapon config restored to (default) config (1416-1424); group ammo stock `−= FLOAT_TYPE_AMMO_ECONOMY · AMMO_USAGE_ACCELERATOR (1.0)` (1428), both bounded [0,100]. (Per-aircraft `FUEL_ECONOMY` / `AMMO_ECONOMY` are DATA-DRIVEN — aircraft database.) Member then sleeps for `rearming_sleep_time + refueling_sleep_time` (1438-1442). Member damage is repaired to initial level on landing (1466).
- **Group-level top-up** (`assess_group_supplies`, `eech group.c:619-…`): for KEYSITE-source groups fully landed (`GROUP_MODE_IDLE`, 675): if group ammo < 100, transfer `required = min(100 − group_ammo·1.0, keysite_ammo)` from keysite stock to group stock (694-704); same for fuel with `FUEL_USAGE_ACCELERATOR` (720-…). Keysite parent used, else nearest friendly keysite ≥ 1 km (689, 731). This is the mechanism by which airbase/FARP stock actually depletes from air operations. GROUP-source groups instead request supply missions when below 100 (635-668).
- **Rearm/refuel duration scaling** (`eech en_suply.c:95-148`):

```
rearming_sleep  = base_time · ( −(5−1)/100 · ammo_supply_level + 5 )      (en_suply.c:107)
refueling_sleep = rearming_time · ( −((5−1)/100) · fuel_supply_level + 5 ) (en_suply.c:133-135)
```

i.e. 1× base time at supply level 100 → 5× at level 0 (`MAX_*_TIME_SCALING_FACTOR = 5`, `eech en_suply.h:67-69`). `base_time` is the group's `FLOAT_TYPE_REARMING_TIME` or, for a specific weapon, `weapon_database[type].rearming_time` (DATA-DRIVEN, reader `eech en_suply.c:102-105`).

### KEYSITE-F10 — Repair system

Behaviour (`eech ks_updt.c:169-222` + `keysite.c:1580-1699` + `mb_msgs.c:2050-2093`):
- `repair_timer` clamped to ≤ 2047 (`eech ks_updt.c:169-170`; pack-width guard).
- **While `KEYSITE_STATE_REPAIRING`**: `repair_timer` counts down; at 0, `repair_client_server_entity_keysite` restores exactly **one** dead building (172-188). That function (`eech keysite.c:1580-1699`) scans building groups first, then regen buildings; restoring a building sets `repair_timer = 10 · ONE_MINUTE` for a normal building (1628) or `20 · ONE_MINUTE` for a regen building (1673) and returns TRUE. When nothing is left to repair it returns FALSE and the state is set back to `KEYSITE_STATE_USABLE` (`eech ks_updt.c:180-187`).
- **While not REPAIRING**: a check runs to create a repair mission if `keysite_strength < keysite_maximum_strength` and the type is `repairable` and no REPAIR task already targets it: `create_repair_task (side, pos, en, priority 10.0, …)` (`eech ks_updt.c:205-221`). NOTE: this check is gated by a **`static` local `task_timer`** shared across *all* keysites — it only fires once per minute globally, and the early `return` also skips the remainder of update for whichever keysite happens to hit it (`eech ks_updt.c:192-199`); quirk faithful to source.
- **Entering REPAIRING**: when the repair-task mover reaches the repair waypoint, the objective keysite's state is set to `KEYSITE_STATE_REPAIRING` (`eech mb_msgs.c:2078-2083`), and the task completes (2090). Capture also sets REPAIRING directly (F13).

| Constant | Value | Source |
|---|---|---|
| repair timer clamp | ≤ 2047 s | eech ks_updt.c:169-170 |
| per-building repair time (normal) | 600 s | eech keysite.c:1628 |
| per-building repair time (regen) | 1200 s | eech keysite.c:1673 |
| repair-need scan interval | 60 s (global static) | eech ks_updt.c:192-199 |
| repair task priority | 10.0 | eech ks_updt.c:215 |

### KEYSITE-F11 — Below-minimum-efficiency transitions (damage states)

Behaviour (on each building loss, `subtract_local_entity_importance_from_keysite`, `eech keysite.c:812-842`):
- If `efficiency <= minimum_efficiency` (0.3):
  - not `repairable` → the **keysite is killed** (`kill_client_server_entity`, 820-825).
  - `repairable` → state set to `KEYSITE_STATE_UNUSABLE` if not already (827-830).
- Else (still above minimum): if currently REPAIRING, the state is bounced back to USABLE (832-841) — a damaged-but-functional keysite stops the active repairing state (repair-task generation in F10 still restores remaining buildings later).

Effects of not-USABLE state elsewhere: task assignment interval doubled (`eech ks_updt.c:120-123`); regen production of new units at the keysite is suspended (`eech rg_updt.c:267`); AI landing-site selection and task creation skip non-usable keysites (`eech ai_misc.c:264,410`, `highlevl.c:1853,2196,2416`, `task.c:1236`).

### KEYSITE-F12 — Capture trigger & probability

Behaviour (troop-insertion-capture waypoint reached, `eech mb_msgs.c:2260-2325`):
- Applies to task `ENTITY_SUB_TYPE_TASK_TROOP_MOVEMENT_INSERT_CAPTURE` (assert 2260). Destination keysite resolved from the task (2262-2271).
- If the keysite already belongs to the troops' side, no capture (2275).
- If `keysite_database[type].ground_strike_target` (2277): capture succeeds with probability that *increases as the keysite is more damaged and the troops less attrited*:

```
d  = (efficiency − minimum) / (1.0 − minimum)            (mb_msgs.c:2287)
d *= member_count / (member_count + losses)              (mb_msgs.c:2293-2297)
r  = frand1()
capture iff d < r                                        (mb_msgs.c:2299-2308)
```

  (d is the *defence* score: full-efficiency keysite + intact troops ⇒ d≈1 ⇒ capture chance ≈ 0; keysite at minimum efficiency ⇒ d=0 ⇒ guaranteed capture.)
- If the type is **not** a ground_strike_target: capture is unconditional (2310-2317). (With stock data this combination — troop_insertion_target true, ground_strike_target false — does not occur.)
- Afterwards the task terminates and the troop division attaches to the keysite (2320-2322).
- Troop-insertion **task generation** targets only enemy keysites that are in use, alive, `troop_insertion_target`, and whose `efficiency < minimum_efficiency` (`eech highlevl.c:1724-1732`); candidate rating = `1·(1−enemy air-defence imap) + 3·friendly base-distance imap + 3·(1−efficiency) + 2·friendly sector ratio`, max 9.0 (`eech highlevl.c:1749-1766`; an importance term is commented out at 1752).
- Debug-only capture paths: RSHIFT+J debug event (`eech ev_debug.c:1823-1854, 2392`) and the campaign-screen base-destroy button — capture if `troop_insertion_target` else kill (`#ifdef DEBUG`, `eech ca_base.c:489-529`).

### KEYSITE-F13 — Capture side effects

Behaviour (`capture_keysite`, `eech keysite.c:1289-1518`; server only, asserts old side ≠ new side 1319):
1. Un-paint old side's sector-side and importance imaps (1330-1334); flip `INT_TYPE_SIDE` and re-parent to new force's keysite list (1340-1342); recompute old side's base-distance imap (1345); paint new side's imaps and base distance (1351-1357).
2. Landed aircraft groups: if the `capture_aircraft` command-line option is set and the group is idle, aircraft and group switch to the new side and get a new callsign (1373-1394); otherwise they are handled by `destroy_keysite` below. Ground groups parented to the keysite are unlinked and become independent groups of the **old** force (1397-1410).
3. `destroy_keysite (en, old_side)` — kills anything landed, redirects inbound aircraft, terminates tasks (1423; see F14).
4. All buildings (building groups and regen groups) switch to the new side (`change_local_keysite_building_sides`, 1429; impl 1524-…).
5. All forces are told to re-check campaign objectives (1437-1444); "keysite captured" text message sent (1450).
6. **Up to 5 buildings are repaired instantly** (loop calling `repair_client_server_entity_keysite`, 1456-1462).
7. State: USABLE if at full strength, else REPAIRING (1468-1475).
8. Regen queue boost for the new side (1483-1517): AIRBASE → +6 helicopter slots, +4 fixed-wing slots, and queue 2× attack-helo, 2× recon-attack-helo, 2× assault-helo, 2× CAS aircraft, 2× multi-role fighter groups; FARP → +2 helicopter slots and 2× recon-attack-helo groups.

### KEYSITE-F14 — Keysite kill & destroy side effects

**Kill** (`kill_local`, `eech ks_dstry.c:282-…`): sets state UNUSABLE (323); if in use — clears `in_use` (327), un-paints sector-side/importance imaps and recomputes base distance (333-339), then `destroy_keysite` (346); sets `alive = FALSE` (350); notifies all forces to check campaign objectives (358-371). Full entity destruction also destroys all task lists, regen, cargo, landing sites (`destroy_server_family`, `eech ks_dstry.c:245-261`).

**destroy_keysite** (`eech keysite.c:945-1283`, called on kill and capture with the *old* side):
- Destroys all cargo crates (970).
- Kills all non-airborne aircraft landed at the keysite, unless their group has a primary task (which lets taxiing/taking-off aircraft escape) (984-1013 with `capture_aircraft` option / 1109-1141 without).
- Inbound aircraft without a primary task get landing site/route locks released and an emergency transfer task to another base (1019-1101, 1147-1226); non-aircraft keysite groups (troops, fresh regen tanks) are killed outright (1097, 1222).
- All unassigned tasks are terminated ABORTED (1233-1242); all tasks targeting the keysite complete as INCOMPLETE (1248-1260).
- Regen queue shrink: AIRBASE → −6 helicopter, −4 fixed-wing; FARP → −2 helicopter (1266-1282).

### KEYSITE-F15 — Task generation & assignment hooks

Behaviour:
- `assign_keysite_tasks (keysite, category)` (`eech assign.c:96-…`) assigns up to `max(assign_task_count, 1)` tasks per pass, holding back `reserve_task_count` non-critical tasks (`eech assign.c:218-220`); driven every 180 s from the keysite update (F4) for RECON/STRIKE/SUPPORT categories (`eech ks_updt.c:111-115`).
- Under attack (`notify_keysite_structure_under_attack`, `eech keysite.c:854-939`): ignores friendly-fire (883-899); sets `assist_timer = DEFAULT_KEYSITE_ASSISTANCE_REQUEST_TIMER` (905); if the aggressor is an aircraft and no CAP task already targets the keysite, creates a CAP task (priority 10.0, duration 15 min) and force-assigns it (907-922); requests force assistance (935-937).
- AI strategy consumes the flags: `requires_cap` / `requires_barcap` keysites get standing CAP/BARCAP objectives (`eech reaction.c:243,257`); `oca_target` gates OCA strike selection (`eech highlevl.c:1353,1540`, `reaction.c:455,897`); `troop_insertion_target` gates capture-mission selection (`eech highlevl.c:1728`, `reaction.c:402,850`); `importance_radius` and `air_coverage_radius` size the influence-map footprints (`eech imaps.c:486,642`).

| Constant | Value | Source |
|---|---|---|
| CAP task priority / duration | 10.0 / 15 min | eech keysite.c:915 |
| assist timer | 60 s ± 20 s | eech keysite.h:67, keysite.c:905 |

### KEYSITE-F16 — FARP enable (side follows sector)

Behaviour (`initialise_keysite_farp_enable`, `eech keysite.c:507-568`; server only): for every FARP in a force's keysite list, if the sector it sits in belongs to that force's side, the FARP's side is set to the force side; if not yet `in_use` it is switched on (`in_use = TRUE`), its imaps painted and base distance updated (543-554); state forced USABLE (556). This is how dormant FARPs activate as the front line moves. (Caller/cadence is outside this module — see Open questions.)

### KEYSITE-F17 — Campaign objectives & victory check

Behaviour (`response_to_check_campaign_objectives`, `eech fc_msgs.c:144-307`; triggered by every keysite capture (`eech keysite.c:1437-1444`) and kill (`eech ks_dstry.c:358-371`)):
- Win path 1 — objectives: for every keysite in the force's CAMPAIGN_OBJECTIVE list: if `troop_insertion_target`, it must be **owned** by this side; otherwise it must be **dead** (182-211). Objective list membership derives from the `campaign_objective` flag (`eech ks_int.c:344`; list built in `create_force_campaign_objectives`, `eech setup.c:126`).
- Win path 2 — annihilation: enemy has no alive+in-use keysite with `air_force_capacity != NONE` (222-249) — i.e. no airbase/carrier/FARP left.
- Win path 3 — no player-controllable combat helicopters remain on the enemy side (255-295).
- Any path met ⇒ `campaign_completed (side, reason)` (301-307).

### KEYSITE-F18 — Warzone (WUT) override of the keysite database

Behaviour: the entire `keysite_database` — including supply usage rates, radii, and every boolean flag — can be rewritten at warzone load from WUT config text (`eech wutcfg.c:510-535`: radii/values by name, flags unpacked from a bitmask, e.g. `requires_cap = (d2>>6)&1`, `troop_insertion_target = (d2>>13)&1`) or from CSV-style gwut files (`eech gwutcfg.c:1487-1506`). All §2.3 values are therefore **defaults**; actual campaign values are DATA-DRIVEN per warzone (readers: `eech wutcfg.c:510-535`, `eech gwutcfg.c:1487-1506`).

### KEYSITE-F19 — Dead / debug-only supply code

- `FUEL_SUPPLY_LEVEL_USAGE` / `AMMO_SUPPLY_LEVEL_USAGE` (10.0) are defined but never referenced anywhere (`eech en_suply.h:71-73`).
- Supply heat-map: `build_supply_heat_map` / `output_supply_heat_map` render cargo and group supply levels into a PSD debug image (`eech en_suply.c:154-391`); diagnostic only, no campaign effect. The "draw frontline groups" step is an empty stub (`eech en_suply.c:231`).
- 75 km supply-range rejection commented out (`eech fc_msgs.c:832-844`); crate air-drop code commented out (`eech mb_msgs.c:1033-1076`); campaign-screen capture button and RSHIFT+J capture are `#ifdef DEBUG` / debug-event only (`eech ca_base.c:489-529`, `ev_debug.c:1823-1854`).

## 4. Interactions

- **Regen (unit production)**: regen buildings only produce when their keysite is alive and USABLE (`eech rg_updt.c:267`); capture/kill add/remove regen queue capacity and queue default groups (F13/F14).
- **Task generation (Spec: taskgen/highlevl)**: keysite flags drive OCA, recon, ground-strike, ship-strike, CAP/BARCAP and troop-insertion target selection; keysite efficiency < 0.3 is the *precondition* for capture missions (`eech highlevl.c:1732`); keysite update assigns generated tasks to based groups every 3 min.
- **Influence maps**: keysites paint sector-side, importance (importance_radius), air coverage (air_coverage_radius) and base-distance maps on creation/capture/kill (`eech imaps.c:486,642`; `keysite.c:1330-1357`).
- **Groups & aircraft**: aircraft groups based at keysites rearm/refuel from keysite stock, with duration scaled 1×–5× by stock level (F9); ground groups get crate deliveries; landing per-member restores fuel/weapons/damage (`eech mb_msgs.c:1404-1466`).
- **Cargo entities**: keysite stock is mirrored as physical crates that supply helicopters physically pick up and deliver (F6/F8) — destroying a keysite destroys its crates (F14).
- **Campaign win**: capture/kill of keysites re-evaluates the three victory paths (F17).
- **Player UI**: usable state, ammo/fuel report flags, map icon/layer, NDB frequency feed the campaign map and base pages (`eech ca_base.c:257-264`); `get_keysite_suitable_for_player` gates player basing (`eech keysite.c:1705-1733`).

## 5. Port mapping

(From the port summary only — no Lua read.)

| Feature | Status | Note |
|---|---|---|
| KEYSITE-F1 type database | NOT PORTED | Port has airbases only, plus procedural depot/fuel/radar installations carrying ground_strike+recon flags; no 9-type flag table. |
| KEYSITE-F2 creation defaults | PARTIAL (keysite) | Airbase-only keysites with ownership/health; NDB, sector linkage, building groups absent (sectors NOT ported). |
| KEYSITE-F3 strength/efficiency | PROXY (keysite_repair) | Port formula efficiency = health×0.5 + ammo×0.25 + fuel×0.25; EECH is strength/maximum from building importance with supply excluded. |
| KEYSITE-F4 update cadence | PARTIAL (keysite_repair) | Port ticks at 60 s matching KEYSITE_UPDATE_SLEEP_TIMER; no 3-min task-assign timer. |
| KEYSITE-F5 supply tick | PROXY (keysite_repair) | Port uses signed supply usage rear +0.5 / forward drain — direction matches EECH producer/consumer signs but rates/floor(10)/cap(100) semantics differ. |
| KEYSITE-F6 cargo crates & request threshold | NOT PORTED | No physical crates, no 75% request threshold. |
| KEYSITE-F7 supply distribution | NOT PORTED | Port supply is finite per-side role pools, consume-on-spawn/recycle-on-RTB, no production and no convoy/air supply missions; road-network distribution not ported. |
| KEYSITE-F8 crate pick-up/drop-off | NOT PORTED | No crate accounting (−10 pickup / set-100 delivery). |
| KEYSITE-F9 group rearm/refuel from stock | PROXY (supply) | Consume-on-spawn/recycle-on-RTB pools stand in for landed rearm/refuel drain and 1×–5× time scaling. |
| KEYSITE-F10 repair system | PROXY (keysite_repair) | Port: 60 s tick, repair gated on ammo & fuel ≥ 50%; EECH: repair-task delivery then one building per 10/20 min, no supply gate. |
| KEYSITE-F11 below-min-efficiency states | PARTIAL | Port has health/capture gating via efficiency; EECH UNUSABLE/kill(non-repairable) split and regen suspension UNKNOWN in port. |
| KEYSITE-F12 capture trigger/probability | PROXY | Port: deterministic troop capture at efficiency < 0.80 + 5 min; EECH: probabilistic `d = (eff−0.3)/0.7 · members/(members+losses)` vs frand1, generated only when eff < 0.3. |
| KEYSITE-F13 capture side effects | PARTIAL (keysite) | Ownership flip + scoring ported; imaps, building side flip, instant 5-building repair, regen queue boosts NOT ported. |
| KEYSITE-F14 kill/destroy side effects | UNKNOWN | Port health/ownership exists; landed-aircraft destruction, emergency transfers, task termination unknown. |
| KEYSITE-F15 task assign/CAP hooks | UNKNOWN | Not described in port summary beyond installation strike/recon flags. |
| KEYSITE-F16 FARP enable by sector | NOT PORTED | Sectors not ported; no FARPs (airbase-only). |
| KEYSITE-F17 campaign objectives/victory | PARTIAL (keysite) | Port has capture scoring; EECH three-path victory check (objectives / no air-capable keysites / no gunships) UNKNOWN. |
| KEYSITE-F18 WUT data override | NOT PORTED | Port has no warzone-config keysite table. |
| KEYSITE-F19 dead/debug code | NOT PORTED | Correctly omitted (dead in EECH too). |

Most consequential gaps: (1) no producer→consumer supply flow — EECH's factory/refinery/port production, crate logistics missions and the 75% request threshold are the campaign's economic engine and its vulnerability to ground strikes (killing a factory starves airbases); (2) capture in EECH is only *offered* below 0.3 efficiency and is probabilistic against troop losses, so the port's 0.80 deterministic rule makes bases far easier to take; (3) supply level does not scale rearm/refuel time in the port, removing the operational-tempo feedback loop.

## 6. Open questions

1. **Who calls `initialise_keysite_farp_enable` and how often?** Callers are outside the keysite module (likely force init / frontline update); cadence not established here.
2. **`raw->in_use` semantics at creation** — which warzone attribute sets `in_use`/side per keysite, and whether non-FARP keysites ever start `in_use = FALSE`, is data/loader behaviour not read here.
3. **The `static float task_timer` in `update_server`** (`eech ks_updt.c:192`) is shared by all keysites and the `return` short-circuits the rest of the update for the keysite that samples it early — is the resulting uneven repair-scan distribution intended? (Looks like a mod-era addition; treat as a source quirk.)
4. **Repair task execution details** — what unit type performs `ENTITY_SUB_TYPE_TASK_REPAIR` and its travel behaviour live in taskgen/group code not covered by this spec; only the waypoint-arrival effect (state→REPAIRING, `eech mb_msgs.c:2078-2083`) is established.
5. **`FLOAT_TYPE_FIXED_OBJECT_IMPORTANCE` values per building** are object-database data; the distribution of per-building importance (hence how many building kills push an airbase under 0.3) is DATA-DRIVEN and not enumerated here.
6. **`command_line_capture_aircraft`** default value (capture vs destroy landed aircraft on keysite capture) was not verified.
7. **Anchorage (carrier) supply**: usage rates are 0/0 yet `report_ammo/fuel_level` are TRUE and carriers are keysites for basing; whether carrier-based groups draw stock via F9 top-up (which they would, from the 10.0 floor upward) with no replenishment path other than delivery was not traced further.
8. **`KEYSITE_SUPPLY_REQUEST_THRESHOLD` vs the 10.0 floor**: since the tick clamps at 10.0 and crate pick-ups can subtract below it transiently (`eech ks_msgs.c:281-292` does not bound), exact low-water behaviour of producer keysites under heavy export was not traced.
