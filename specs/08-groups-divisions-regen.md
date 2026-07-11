# EECH Spec 08 — Groups, Divisions & Regeneration

Sources:
- `aphavoc/source/entity/special/group/` — `gp_dbase.c/.h`, `group.c/.h`, `gp_creat.c`, `gp_dstry.c`, `gp_updt.c`, `gp_msgs.c`, `gp_int.c`, `gp_float.c`, `gp_funcs.c`
- `aphavoc/source/entity/special/division/` — `division.c/.h`, `dv_dbase.c/.h`, `dv_creat.c`, `dv_msgs.c`
- `aphavoc/source/entity/special/regen/` — `regen.c/.h`, `rg_dbase.c/.h`, `rg_creat.c`, `rg_updt.c/.h`
- `aphavoc/source/entity/system/en_types/` — `en_sbtyp.h`, `en_group.h`, `en_suply.c/.h`
- Supporting: `entity/special/keysite/keysite.c`, `entity/mobile/mb_msgs.c`, `entity/mobile/aircraft/helicop/hc_dstry.c`, `entity/mobile/aircraft/fixwing/fw_dstry.c`, `entity/mobile/vehicle/routed/rv_dstry.c`, `ai/faction/faction.c`, `ai/faction/popread.c`, `ai/parser/parsgen.c`, `ai/taskgen/assign.c`, `modules/maths/constant.h`

## 1. Overview

A **group** is EECH's campaign-level unit container: every mobile campaign entity (helicopter, fixed wing, routed vehicle, ship, person) is a member of exactly one group. Groups own the task/guide stack, the supply pools (ammo/fuel), the callsign, kills/losses, and the formation. All per-type behaviour comes from a single static database `group_database[NUM_ENTITY_SUB_TYPE_GROUPS]` (26 types, eech gp_dbase.c:81-1150).

A **division** is a lightweight organisational entity above groups (company → division hierarchy) used almost only for naming ("1st Armoured Brigade", "A Company") and grouping on the map; it has no AI behaviour of its own (its message handlers are debug-only, eech dv_msgs.c:139-152).

**Regeneration** replaces destroyed aircraft and routed vehicles: each destruction pushes a `(type, sub_type, group_type)` record into a per-side, per-category FIFO ring queue; **regen entities** (created from special "regen" buildings at keysites) tick on a per-side frequency and, if the force has hardware reserves of that category, spawn one replacement member in a fresh group at their keysite. The per-category regen "database" (`rg_dbase.c`) is **empty** — there are no per-category timers in the C source; cadence is a single per-side float loaded from campaign data.

## 2. Data model

### 2.1 Enums

- `enum ENTITY_SUB_TYPE_GROUPS` — 26 group types (eech en_sbtyp.h:306-338): 8 helicopter, 6 fixed-wing, 8 ground (`ANTI_AIRCRAFT`, `PRIMARY_FRONTLINE`, `SECONDARY_FRONTLINE`, `SELF_PROPELLED_ARTILLERY`, `SELF_PROPELLED_MLRS`, `STATIC_INFANTRY`, `INFANTRY`, `INFANTRY_PATROL`), 3 sea (`ASSAULT_SHIP`, `FRIGATE`, `LANDING_CRAFT`), plus `BUILDINGS`.
- `enum GROUP_CATEGORY_TYPES` — `HELICOPTERS`, `AIRCRAFT`, `ARMOUR`, `WARSHIPS` (eech en_group.h:67-75). Infantry and buildings use `NUM_GROUP_CATEGORY_TYPES` (= no category, eech gp_dbase.c:871,912,953,1117).
- `enum GROUP_FRONTLINE_FLAG_TYPES` — `NONE`, `PRIMARY`, `SECONDARY`, `ARTILLERY` (eech group.h:197-205).
- `enum GROUP_MODE_TYPES` — `GROUP_MODE_IDLE`, `GROUP_MODE_BUSY` (eech ai_extrn.h:91-96). Derived, not stored: BUSY iff group has any child in `LIST_TYPE_GUIDE_STACK` (eech gp_int.c:445-458).
- `enum GROUP_CALLSIGN_TYPES` — 92 named callsigns, `ANGEL`…`WOLFPACK` (eech group.h:73-166).
- `enum PLATOON_ID_TYPES` — `NONE`, `NUMBER`, `LETTER`, `CALLSIGN`, `KEYSITE` (eech division.h:92-102); `enum PLATOON_SHORT_NAME_TYPES` — `INVALID`, `CALLSIGN`, `ARMOUR`, `SHIPS`, `KEYSITE` (eech division.h:108-118).
- `enum ENTITY_SUB_TYPE_DIVISION` — 6 division types + 11 company types (eech en_sbtyp.h:182-204).
- `enum ENTITY_SUB_TYPE_REGEN` — `FIXED_WING`, `HELICOPTER`, `GROUND`, `PEOPLE`, `SEA`, `NONE` (eech en_sbtyp.h:454-462).
- `enum REGENERATION_BUILDING_TYPES` — `INVALID`, `NONE`, `FIXEDWING`, `HELICOPTER`, `ROUTED_VEHICLE`, `PEOPLE`, `SHIP_VEHICLE` (eech regen.h:99-109).

### 2.2 Structs

- `struct GROUP_DATA` (one DB row, eech gp_dbase.h:67-127): `full_name`, `group_short_name`, `group_category`, `registry_list_type`, `group_list_type`, `movement_type`, `default_landing_type`, `default_entity_type`, `default_blue_force_sub_type`, `default_red_force_sub_type`, `default_group_formation`, `default_group_division`, `maximum_groups_per_division`, `platoon_name`, `platoon_short_name_type`, `map_layer_type`, `map_icon`, `rearming_time` (float), bitfields `frontline_flag`, `local_only_group`, `default_engage_enemy`, `amalgamate:1`, `platoon_id_type:3`, `maximum_member_count:5`, `minimum_idle_count:4`, `resupply_source`, and `ai_stats` {air attack, ground attack, movement speed, movement stealth, cargo space, troop space}. The table is non-`const` so WUT config files can overwrite rows at load (eech gp_dbase.c:79-81; readers eech gwutcfg.c:1541-1548, eech wutcfg.c:678-688 — DATA-DRIVEN override).
- `struct GROUP` entity data (eech group.h:211-259): `sub_type`; list roots `member_root`, `guide_stack_root`, `task_dependent_root`; links `group_link`, `division_link`, `pilot_lock_link`, `registry_link`, `task_dependent_link`, `update_link`; `group_list_type`; floats `sleep`, `last_seen_time`, `assist_timer`; `last_known_position`; `supplies` {ammo_supply_level, fuel_supply_level}; bitfields `alive`, `engage_enemy`, `group_callsign`, `group_formation`, `kills`, `losses`, `member_count`, `multiplayer_group`, `route_node`, `side`, `unique_id`, `verbose_operational_state`; `division_name[STRING_TYPE_DIVISION_NAME_MAX_LENGTH+1]`.
- `struct DIVISION` entity data (eech division.h:67-86): `sub_type`, `division_id`, `division_root` (child groups/sub-divisions), links `division_link` (to parent force/division), `division_headquarters_link` (to keysite), `division_name`.
- `struct DIVISION_DATA` (eech dv_dbase.h:67-77): `full_name` (printf format), `default_group_division` (parent division type), `maximum_groups_per_division`.
- `struct DIVISION_ID_DATA` (eech division.c:79-88): per side/type `valid`, `count`, `next`, `number_list` — pool of historical unit numbers loaded from campaign data (`FILE_TAG_DIVISION_ID_LIST`, eech parsgen.c:1524-1538+), cycled by `get_next_free_division_id` with wraparound warning (eech division.c:751-788).
- `struct REGEN` entity data (eech regen.h:67-93): `sub_type` (regen category), `position`, `member_root` (the regen building), links `current_waypoint_link`, `regen_link` (to keysite), `update_link`; `sleep`; bitfields `alive`, `regen_creation_sub_type`, `side`.
- `struct REGEN_LIST_ELEMENT` (eech regen.h:117-126): `type`, `sub_type`, `group` (all int, -1 = empty).
- `struct REGEN_MANAGEMENT_ELEMENT` (eech regen.h:128-136): `size`, `count`, `front` — ring-buffer bookkeeping.
- `struct REGEN_DATA` (eech rg_dbase.h:64-68) is **EMPTY** (`struct REGEN_DATA { };`) and `regen_database[NUM_ENTITY_SUB_TYPE_REGENS]` has an **empty initialiser** (eech rg_dbase.c:79-82). There are no per-category regen timers/delays anywhere in the C source; this table is vestigial.

### 2.3 Global regen state

- `regen_queue[NUM_ENTITY_SIDES][NUM_ENTITY_SUB_TYPE_REGENS]` — heap-allocated ring buffers (eech regen.c:99-100, alloc eech rg_updt.c:892-922).
- `regen_manager[NUM_ENTITY_SIDES][NUM_ENTITY_SUB_TYPE_REGENS]` (eech regen.c:102-103).
- `regen_frequency[NUM_ENTITY_SIDES]` (float seconds, eech regen.c:112-113) — set only by campaign-file tag `FILE_TAG_REGEN_FREQUENCY` (eech parsgen.c:1500-1522; DATA-DRIVEN value, asserted > 0).
- `regen_to_landing_conversion[]` — regen category → landing sub-type map (eech regen.c:129-134).
- `regeneration_object_database[OBJECT_3D_LAST]` — 3D object → regen category, discovered by searching each object model for `OBJECT_3D_SUB_OBJECT_REGEN_FIXED_WING / _HELICOPTER / _ROUTED_VEHICLE / _PERSON` sub-objects (eech regen.c:216-322). The `REGEN_SHIP_VEHICLE` search is commented out (dead, eech regen.c:284-296).

## 3. Features

### GROUP-F1 — Group type database (full table)

Every group type's full row from `group_database` (eech gp_dbase.c:81-1150). All 26 rows; line = start of that row's initialiser.

**Table 1 — identity & organisation** (columns: full name | short name | category | registry list | group list | movement | landing type | member entity type | blue member sub-type | red member sub-type | formation | default company (division) | max groups/company)

| # | Group type (line) | Full name | Short | Category | Registry | Group list | Move | Landing | Member entity type | Blue default | Red default | Formation | Default company | Max grp/div |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | ATTACK_HELICOPTER (gp_dbase.c:89) | Attack Helicopters | Attack | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | AH64D_APACHE_LONGBOW | MI28N_HAVOC_B | ECHELON_LEFT | HC_ATTACK_COMPANY | 5 |
| 1 | MARINE_ATTACK_HELICOPTER (gp_dbase.c:130) | Marine Attack Helicopters | Marine Attack | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | AH1T_SEACOBRA | KA29_HELIX_B | ECHELON_LEFT | HC_ATTACK_COMPANY | 5 |
| 2 | ASSAULT_HELICOPTER (gp_dbase.c:171) | Assault Helicopters | Assault | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | UH60_BLACK_HAWK | MI24D_HIND | WEDGE | HC_ATTACK_COMPANY | 5 |
| 3 | MARINE_ASSAULT_HELICOPTER (gp_dbase.c:212) | Marine Assault Helicopters | Marine Assault | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | CH46E_SEA_KNIGHT | KA29_HELIX_B | WEDGE | HC_ATTACK_COMPANY | 5 |
| 4 | RECON_HELICOPTER (gp_dbase.c:253) | Recon Helicopters | Recon | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | OH58D_KIOWA_WARRIOR | KA50_HOKUM | ECHELON_LEFT | HC_ATTACK_COMPANY | 5 |
| 5 | RECON_ATTACK_HELICOPTER (gp_dbase.c:294) | Recon/Attack Helicopters | Recon/Attack | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | RAH66_COMANCHE | KA52_HOKUM_B | ECHELON_LEFT | HC_ATTACK_COMPANY | 5 |
| 6 | MEDIUM_LIFT_TRANSPORT_HELICOPTER (gp_dbase.c:335) | Medium-Lift Transport Helicopters | Medium-Lift | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | CH3_JOLLY_GREEN_GIANT | MI17_HIP | WEDGE | HC_TRANSPORT_COMPANY | 5 |
| 7 | HEAVY_LIFT_TRANSPORT_HELICOPTER (gp_dbase.c:376) | Heavy-Lift Transport Helicopters | Heavy-Lift | HELICOPTERS | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_HELICOPTER | HELICOPTER | CH47D_CHINOOK | MI6_HOOK | WEDGE | HC_TRANSPORT_COMPANY | 5 |
| 8 | MULTI_ROLE_FIGHTER (gp_dbase.c:417) | Multi-Role Fighters | Fighter | AIRCRAFT | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_FIXED_WING | FIXED_WING | F16_FIGHTING_FALCON | MIG29_FULCRUM | ROW_LEFT | FW_FIGHTER_COMPANY | 5 |
| 9 | CARRIER_BORNE_ATTACK_AIRCRAFT (gp_dbase.c:458) | Carrier-Borne Attack Aircraft | Navy Attack | AIRCRAFT | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_FIXED_WING | FIXED_WING | AV8B_HARRIER | YAK41_FREESTYLE | ROW_LEFT | FW_FIGHTER_COMPANY | 5 |
| 10 | CARRIER_BORNE_INTERCEPTOR (gp_dbase.c:499) | Carrier-Borne Interceptors | Navy Fighter | AIRCRAFT | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_FIXED_WING | FIXED_WING | FA18_HORNET | SU33_FLANKER | ROW_LEFT | FW_FIGHTER_COMPANY | 5 |
| 11 | CLOSE_AIR_SUPPORT_AIRCRAFT (gp_dbase.c:540) | Close Air Support Aircraft | CAS | AIRCRAFT | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_FIXED_WING | FIXED_WING | A10A_THUNDERBOLT | SU25_FROGFOOT | ROW_LEFT | FW_ATTACK_COMPANY | 5 |
| 12 | MEDIUM_LIFT_TRANSPORT_AIRCRAFT (gp_dbase.c:581) | Medium-Lift Transport Aircraft | Medium-Lift | AIRCRAFT | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_FIXED_WING_TRANSPORT | FIXED_WING | C130J_HERCULES_II | AN12B_CUB | WEDGE | FW_TRANSPORT_COMPANY | 5 |
| 13 | HEAVY_LIFT_TRANSPORT_AIRCRAFT (gp_dbase.c:622) | Heavy-Lift Transport Aircraft | Heavy-Lift | AIRCRAFT | AIR_REGISTRY | KEYSITE_GROUP | AIR | LANDING_FIXED_WING_TRANSPORT | FIXED_WING | C17_GLOBEMASTER_III | IL76MD_CANDID_B | WEDGE | FW_TRANSPORT_COMPANY | 5 |
| 14 | ANTI_AIRCRAFT (gp_dbase.c:663) | Air Defence Artillery | SAM/AAA | ARMOUR | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_GROUND | ANTI_AIRCRAFT | M48A1_CHAPARRAL | SA13_GOPHER | WEDGE | ADA_COMPANY | 10 |
| 15 | PRIMARY_FRONTLINE (gp_dbase.c:704) | Frontline | Frontline | ARMOUR | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_GROUND | ROUTED_VEHICLE | M1A2_ABRAMS | T80U | 80M_ROAD_NODE_16_TANKS | ARMOURED_COMPANY | 3 |
| 16 | SECONDARY_FRONTLINE (gp_dbase.c:745) | Support | Support | ARMOUR | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_GROUND | ROUTED_VEHICLE | M1A2_ABRAMS | T80U | 80M_ROAD_NODE_16_TANKS | ARMOURED_COMPANY | 3 |
| 17 | SELF_PROPELLED_ARTILLERY (gp_dbase.c:786) | Artillery | Artillery | ARMOUR | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_GROUND | ROUTED_VEHICLE | M109A2 | 2S19 | 80M_ROAD_NODE_16_TANKS | ARTILLERY_COMPANY | 1 |
| 18 | SELF_PROPELLED_MLRS (gp_dbase.c:827) | MLRS | MLRS | ARMOUR | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_GROUND | ROUTED_VEHICLE | M270_MLRS | BM21_GRAD | 80M_ROAD_NODE_16_TANKS | ARTILLERY_COMPANY | 1 |
| 19 | STATIC_INFANTRY (gp_dbase.c:868) | Infantry | Infantry | (none) | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_PEOPLE | ANTI_AIRCRAFT ("static AAA people on buildings") | US_INFANTRY_SAM_STANDING | CIS_INFANTRY_SAM_STANDING | WEDGE | INFANTRY_COMPANY | 8 |
| 20 | INFANTRY (gp_dbase.c:909) | Infantry | Infantry | (none) | GROUND_REGISTRY | INDEPENDENT_GROUP | GROUND | LANDING_PEOPLE | PERSON | US_INFANTRY | CIS_INFANTRY | WEDGE | SPECIAL_FORCES_COMPANY | 4 |
| 21 | INFANTRY_PATROL (gp_dbase.c:950) | Infantry | Infantry | (none) | GROUND_REGISTRY | KEYSITE_GROUP | GROUND | LANDING_PEOPLE | PERSON | US_INFANTRY | CIS_INFANTRY | WEDGE | INFANTRY_COMPANY | 1 |
| 22 | ASSAULT_SHIP (gp_dbase.c:991) | Assault Ships | Assault | WARSHIPS | SEA_REGISTRY | INDEPENDENT_GROUP | SEA | LANDING_SEA | SHIP_VEHICLE | TARAWA_CLASS | KIEV_CLASS | COLUMN | CARRIER_COMPANY | 5 |
| 23 | FRIGATE (gp_dbase.c:1032) | Frigates | Frigate | WARSHIPS | SEA_REGISTRY | INDEPENDENT_GROUP | SEA | LANDING_SEA | SHIP_VEHICLE | OLIVER_HAZARD_PERRY_CLASS | KRIVAK_II_CLASS | COLUMN | CARRIER_COMPANY | 5 |
| 24 | LANDING_CRAFT (gp_dbase.c:1073) | Landing Craft | LCU | WARSHIPS | SEA_REGISTRY | INDEPENDENT_GROUP | SEA | LANDING_SEA | SHIP_VEHICLE | LCAC | AIST_CLASS | COLUMN | CARRIER_COMPANY | 5 |
| 25 | BUILDINGS (gp_dbase.c:1114) | Buildings | Buildings | (none) | (INVALID) | BUILDING_GROUP | NONE | LANDING_GROUND | SITE | SITE_TARAWA | SITE_TARAWA | NONE | (none) | 0 |

**Table 2 — behaviour columns** (platoon name fmt | short-name type | map layer | map icon | rearm time (s) | frontline flag | local-only | engage enemy | amalgamate | platoon ID type | max members | min idle | resupply source)

| # | Group type | Platoon fmt | Short-name | Map layer | Map icon | Rearm s | Frontline | Local | Engage | Amalg | ID type | Max mem | Min idle | Resupply |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | ATTACK_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | HELICOPTER | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 2 | KEYSITE |
| 1 | MARINE_ATTACK_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | HELICOPTER | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 0 | KEYSITE |
| 2 | ASSAULT_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | HELICOPTER | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 0 | KEYSITE |
| 3 | MARINE_ASSAULT_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | HELICOPTER | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 0 | KEYSITE |
| 4 | RECON_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | HELICOPTER | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 0 | KEYSITE |
| 5 | RECON_ATTACK_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | HELICOPTER | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 3 | KEYSITE |
| 6 | MEDIUM_LIFT_TRANSPORT_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | TRANSPORT_HELICOPTER | 60.0 | NONE | F | F | T | CALLSIGN | 2 | 0 | KEYSITE |
| 7 | HEAVY_LIFT_TRANSPORT_HELICOPTER | "N/A" | CALLSIGN | AIRCRAFT | TRANSPORT_HELICOPTER | 60.0 | NONE | F | F | T | CALLSIGN | 2 | 0 | KEYSITE |
| 8 | MULTI_ROLE_FIGHTER | "N/A" | CALLSIGN | AIRCRAFT | JET | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 1 | KEYSITE |
| 9 | CARRIER_BORNE_ATTACK_AIRCRAFT | "N/A" | CALLSIGN | AIRCRAFT | JET | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 1 | KEYSITE |
| 10 | CARRIER_BORNE_INTERCEPTOR | "N/A" | CALLSIGN | AIRCRAFT | JET | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 0 | KEYSITE |
| 11 | CLOSE_AIR_SUPPORT_AIRCRAFT | "N/A" | CALLSIGN | AIRCRAFT | JET | 60.0 | NONE | F | T | T | CALLSIGN | 4 | 1 | KEYSITE |
| 12 | MEDIUM_LIFT_TRANSPORT_AIRCRAFT | "N/A" | CALLSIGN | AIRCRAFT | TRANSPORT_AIRCRAFT | 60.0 | NONE | F | F | T | CALLSIGN | 2 | 0 | KEYSITE |
| 13 | HEAVY_LIFT_TRANSPORT_AIRCRAFT | "N/A" | CALLSIGN | AIRCRAFT | TRANSPORT_AIRCRAFT | 60.0 | NONE | F | F | T | CALLSIGN | 2 | 0 | KEYSITE |
| 14 | ANTI_AIRCRAFT | "%s Battalion" | ARMOUR | SAM_AAA | AAA | 60.0 | NONE | T | T | F | NUMBER | 4 | 0 | GROUP |
| 15 | PRIMARY_FRONTLINE | "%s Battalion" | ARMOUR | ARMOUR | TANK | 60.0 | PRIMARY | F | T | T | NUMBER | 16 | 0 | GROUP |
| 16 | SECONDARY_FRONTLINE | "%s Battalion" | ARMOUR | ARMOUR | APC | 60.0 | SECONDARY | F | T | T | NUMBER | 16 | 0 | GROUP |
| 17 | SELF_PROPELLED_ARTILLERY | "%s Battalion" | ARMOUR | ARMOUR | ARTILLERY | 60.0 | ARTILLERY | F | T | T | NUMBER | 4 | 0 | GROUP |
| 18 | SELF_PROPELLED_MLRS | "%s Battalion" | ARMOUR | ARMOUR | ARTILLERY | 60.0 | ARTILLERY | F | T | T | NUMBER | 4 | 0 | GROUP |
| 19 | STATIC_INFANTRY | "%c Company" | ARMOUR | NONE | NONE | 60.0 | NONE | T | T | F | LETTER | 1 | 0 | NONE |
| 20 | INFANTRY | "%c Company" | ARMOUR | NONE | NONE | 60.0 | NONE | F | F | F | LETTER | 8 | 0 | NONE |
| 21 | INFANTRY_PATROL | "%c Company" | ARMOUR | NONE | NONE | 60.0 | NONE | F | F | F | LETTER | 8 | 0 | NONE |
| 22 | ASSAULT_SHIP | "%s" | KEYSITE | SHIPS | CARRIER | 60.0 | NONE | F | T | F | KEYSITE | 1 | 0 | KEYSITE |
| 23 | FRIGATE | "Frigates (%s)" | SHIPS | SHIPS | SHIP | 60.0 | NONE | F | T | T | KEYSITE | 2 | 0 | KEYSITE |
| 24 | LANDING_CRAFT | "Landing Craft (%s)" | SHIPS | SHIPS | SHIP | 60.0 | NONE | F | F | T | KEYSITE | 4 | 0 | KEYSITE |
| 25 | BUILDINGS | "N/A" | INVALID | NONE | NONE | 0.0 | NONE | T | F | F | NONE | 0 | 0 | NONE |

All rearm times are written `(60.0 * 1.0)` in source (e.g. eech gp_dbase.c:107).

**Table 3 — ai_stats** (air attack | ground attack | movement speed | movement stealth | cargo space | troop space)

| # | Group type | Air | Gnd | Spd | Stealth | Cargo | Troop |
|---|---|---|---|---|---|---|---|
| 0 | ATTACK_HELICOPTER | 6 | 8 | 3 | 6 | 0 | 0 |
| 1 | MARINE_ATTACK_HELICOPTER | 4 | 5 | 3 | 6 | 0 | 0 |
| 2 | ASSAULT_HELICOPTER | 0 | 8 | 2 | 6 | 0 | 10 |
| 3 | MARINE_ASSAULT_HELICOPTER | 0 | 0 | 2 | 5 | 4 | 0 |
| 4 | RECON_HELICOPTER | 0 | 0 | 4 | 8 | 0 | 0 |
| 5 | RECON_ATTACK_HELICOPTER | 7 | 8 | 4 | 8 | 0 | 0 |
| 6 | MEDIUM_LIFT_TRANSPORT_HELICOPTER | 0 | 0 | 1 | 4 | 8 | 0 |
| 7 | HEAVY_LIFT_TRANSPORT_HELICOPTER | 0 | 0 | 1 | 4 | 10 | 0 |
| 8 | MULTI_ROLE_FIGHTER | 10 | 6 | 10 | 0 | 0 | 0 |
| 9 | CARRIER_BORNE_ATTACK_AIRCRAFT | 5 | 8 | 8 | 0 | 0 | 0 |
| 10 | CARRIER_BORNE_INTERCEPTOR | 10 | 2 | 10 | 0 | 0 | 0 |
| 11 | CLOSE_AIR_SUPPORT_AIRCRAFT | 0 | 10 | 8 | 0 | 0 | 0 |
| 12 | MEDIUM_LIFT_TRANSPORT_AIRCRAFT | 0 | 0 | 6 | 0 | 8 | 0 |
| 13 | HEAVY_LIFT_TRANSPORT_AIRCRAFT | 0 | 0 | 5 | 0 | 10 | 0 |
| 14 | ANTI_AIRCRAFT | 10 | 0 | 0 | 0 | 0 | 0 |
| 15 | PRIMARY_FRONTLINE | 6 | 10 | 0 | 0 | 0 | 0 |
| 16 | SECONDARY_FRONTLINE | 5 | 7 | 0 | 0 | 0 | 0 |
| 17 | SELF_PROPELLED_ARTILLERY | 0 | 10 | 0 | 0 | 0 | 0 |
| 18 | SELF_PROPELLED_MLRS | 0 | 10 | 0 | 0 | 0 | 0 |
| 19 | STATIC_INFANTRY | 6 | 0 | 0 | 0 | 0 | 0 |
| 20 | INFANTRY | 6 | 0 | 0 | 0 | 0 | 0 |
| 21 | INFANTRY_PATROL | 6 | 0 | 0 | 0 | 0 | 0 |
| 22 | ASSAULT_SHIP | 10 | 0 | 0 | 0 | 0 | 0 |
| 23 | FRIGATE | 8 | 0 | 0 | 0 | 0 | 0 |
| 24 | LANDING_CRAFT | 0 | 0 | 0 | 0 | 0 | 0 |
| 25 | BUILDINGS | 0 | 0 | 0 | 0 | 0 | 0 |

Note on composition: the DB does not fix *initial* member counts — actual campaign populations come from warzone population data (`popread.c`, DATA-DRIVEN). The DB gives the per-side default member sub-type (used by regen and defaults), `maximum_member_count` (amalgamation cap and creation cap), and `default_entity_type`.

### GROUP-F2 — Group entity creation

`create_local` (eech gp_creat.c:79-252):
- Defaults: `member_count = 0`, `engage_enemy = FALSE`, `alive = TRUE`, `division_name = "UNKNOWN"`, `supplies.ammo/fuel = 100.0` (eech gp_creat.c:131-146).
- Mandatory: valid group sub-type, side != NEUTRAL, `sleep == 0` (eech gp_creat.c:162-166). Side inherited from list parent if uninitialised (eech gp_creat.c:178-181).
- `group_formation` = DB `default_group_formation` (eech gp_creat.c:193). Callsign assigned at creation (eech gp_creat.c:201, see GROUP-F10).
- Linked into `group_list_type` from DB; an `INDEPENDENT_GROUP` created with a keysite parent is coerced to `KEYSITE_GROUP` (eech gp_creat.c:211-221).
- If DB registry list != INVALID, linked into force registry (`AIR/GROUND/SEA_REGISTRY`) and counted into force info via `add_group_type_to_force_info` (eech gp_creat.c:237-248).
- `INT_TYPE_ENGAGE_ENEMY` is set from DB `default_engage_enemy` where groups are created by faction code (eech faction.c:1166,1180; getter fallback eech gp_int.c:344,375).

### GROUP-F3 — Member management

- `LINK_CHILD(MEMBER)`: `member_count++`; player member sets `multiplayer_group = TRUE`; fixed members add importance to parent keysite strength; mobile members notify campaign screen (eech gp_msgs.c:89-168).
- `UNLINK_CHILD(MEMBER)`: `member_count--`; `multiplayer_group` recomputed by scanning remaining members; fixed member importance subtracted from keysite (eech gp_msgs.c:174-239).
- `set_group_member_numbers` renumbers members 0..n-1 in list order (eech group.c:769-793); `set_group_formation_positions` copies member number → formation position (eech group.c:799-816). `get_local_group_member_count` walks the list (eech group.c:185-207).

### GROUP-F4 — Group modes, sleep & task-assignment gating

- `GROUP_MODE` is derived: BUSY iff guide stack non-empty, else IDLE (eech gp_int.c:445-458).
- Server update (only while on the update list): decrement `sleep` and `assist_timer` by frame delta, clamp to 0; when both reach 0 the group removes itself from the update list (eech gp_updt.c:79-108). Groups are therefore event-driven, not polled.
- Task assignment (`get_suitable_registered_group`, eech assign.c:401-518) requires, in order: no player pilot lock (assign.c:445); not an ASSAULT_SHIP (hardcoded exclusion, assign.c:451-456); `GROUP_MODE_IDLE` (assign.c:459); `sleep == 0.0` (assign.c:461); same side as task (assign.c:463); per-type idle-group count strictly greater than DB `minimum_idle_count` (assign.c:467-474) — i.e. the reserve of idle groups of that type is never fully committed; member count >= task minimum (assign.c:476); all members awake; suitability score > 0; task-specific checks; locality/cruise-speed feasibility (assign.c:478-503).

| Constant | Value | Source |
|---|---|---|
| minimum_idle_count (per type) | see Table 2 | eech gp_dbase.c (rows) |
| assignment idle test | `idle_count > minimum_idle_count` | eech assign.c:474 |

### GROUP-F5 — Supplies: consumption on landing, rearm/refuel sleep, keysite draw

Group carries `ammo_supply_level` / `fuel_supply_level` (0..100, start 100, eech gp_creat.c:145-146). On each AI member landing (mb_msgs.c landed handler), if group `resupply_source == KEYSITE`:
- `fuel -= FLOAT_TYPE_FUEL_ECONOMY(member) * FUEL_USAGE_ACCELERATOR`; member's fuel reset to default weight (eech mb_msgs.c:1402-1410).
- `ammo -= FLOAT_TYPE_AMMO_ECONOMY(member) * AMMO_USAGE_ACCELERATOR`; member's weapon config restored (eech mb_msgs.c:1416-1432).
- Member `FLOAT_TYPE_SLEEP` = rearm sleep + refuel sleep (eech mb_msgs.c:1438-1442) where
  - rearm: `sleep = base * (-(MAX_REARMING_TIME_SCALING_FACTOR-1)/100 * ammo_level + MAX_REARMING_TIME_SCALING_FACTOR)`, base = group `FLOAT_TYPE_REARMING_TIME` (DB `rearming_time`, getter eech gp_float.c:251) (eech en_suply.c:95-120);
  - refuel: same form with fuel level (eech en_suply.c:126-148). At level 100 the factor is 1.0×base; at level 0 it is 5.0×base.
- Then `assess_group_supplies` (eech group.c:619-763): for `RESUPPLY_SOURCE_KEYSITE` groups that are IDLE and below 100, transfer `required = 100 - level*ACCELERATOR` (bounded by keysite stock) from keysite `FLOAT_TYPE_AMMO/FUEL_SUPPLY_LEVEL` to the group (eech group.c:669-761); for `RESUPPLY_SOURCE_GROUP` (ground) groups below 100, send `ENTITY_MESSAGE_FORCE_LOW_ON_SUPPLIES` to force to spawn a supply mission (ammo first, else fuel) (eech group.c:635-667).

| Constant | Value | Source |
|---|---|---|
| MAX_REARMING_TIME_SCALING_FACTOR | 5 | eech en_suply.h:67 |
| MAX_REFUELING_TIME_SCALING_FACTOR | 5 | eech en_suply.h:69 |
| FUEL_USAGE_ACCELERATOR | 1.0 | eech en_suply.h:79 |
| AMMO_USAGE_ACCELERATOR | 1.0 | eech en_suply.h:83 |
| group rearming_time (all types except BUILDINGS) | 60.0 s | eech gp_dbase.c:107 etc. |

### GROUP-F6 — Amalgamation

Triggered when a member lands and its group is IDLE and DB `amalgamate` is set: scan sibling keysite groups for another IDLE amalgamate-capable group and merge (eech mb_msgs.c:1496-1534). `amalgamate_groups` (eech group.c:381-555): requires identical sub-type and side, both IDLE; merges only if combined count <= DB `maximum_member_count` (eech group.c:422); moves all members to receiver, sums kills/losses, renumbers members, then kills the empty donor group (eech group.c:467-509). Debug builds warn if merged members are > 10 km apart (eech group.c:519).

### GROUP-F7 — Retaliation & assistance requests

`ENTITY_MESSAGE_ENTITY_FIRED_AT` on a group from an enemy (eech gp_msgs.c:295-359):
- If `assist_timer == 0`, set it to `DEFAULT_GROUP_ASSISTANCE_REQUEST_TIMER = ONE_MINUTE + sfrand1()*20.0` seconds (eech group.h:67; ONE_MINUTE = 60 s, eech modules/maths/constant.h:145,163) and send `ENTITY_MESSAGE_REQUEST_ASSISTANCE` to the force.
- If `INT_TYPE_ENGAGE_ENEMY` and not already running an ENGAGE task and `group_task_specific_retaliation_checks` passes (task ROE etc., eech group.c:1277+), create an engage task on the aggressor for all members (eech gp_msgs.c:342-355).
`ENTITY_MESSAGE_ENTITY_TARGETED`: treated as fired-at only when the aggressor is a player on HARD difficulty with radar on (eech gp_msgs.c:365-405).

### GROUP-F8 — Return to base / task completion

On primary-task completion the group (unless the task ended by group death or the waypoint route is complete) calls `group_return_to_base` (eech gp_msgs.c:1163-1176). `group_return_to_base` (eech group.c:822-971): terminates all engage tasks; finds the last objective waypoint on the current route; projects remaining waypoints onto the group→final-waypoint axis and jumps the guide to the closest waypoint that is on the homeward side (`set_guide_new_waypoint`, eech group.c:970), i.e. the outbound route is truncated and flown home from the nearest sensible point.

### GROUP-F9 — Group death, disband, emergency transfer

- When a mobile member dies, the group receives `ENTITY_MESSAGE_MOBILE_KILLED` (eech gp_msgs.c:1281-1386): if `member_count == 0` the group itself is killed with all tasks terminated (`kill_client_server_group_entity`, eech gp_msgs.c:1298-1307); otherwise dependent tasks are re-assessed for completeness and the dead member is removed from guide valid-member masks (solo-task guides destroyed outright, eech gp_msgs.c:1343-1382).
- `kill_client_server_group_entity` (eech group.c:1079-1124): notify every guide `GROUP_KILLED`, complete all dependent tasks, then kill the entity.
- `kill_local` (eech gp_dstry.c:265-350): removes type from force info, frees callsign; asserts group is empty with no guides; groups with DB `local_only_group == TRUE` are unlinked but **not destroyed** (entity index must not be reused across save/restore, eech gp_dstry.c:320-341); others are destroyed.
- `destroy_local` unlinks registry, division, task-dependents, pilot lock, keysite list, guide stack, update list (eech gp_dstry.c:79-160). Family destroy also destroys all members (eech gp_dstry.c:228-244).
- `create_group_emergency_transfer_task` (eech group.c:1130-1211): when a group must vacate (e.g. keysite lost), terminate all tasks, find closest friendly landing with enough free sites for the whole group, create a TRANSFER task (helicopter or fixed-wing variant, priority 10.0); if no site or assignment fails, **kill all members** (eech group.c:1188,1207).

### GROUP-F10 — Callsign pool

92-name pool; per-side usage counts (eech group.h:174-191). Assignment (aircraft groups only, server): start index = entity index mod 92, linear-probe to first name unused by that side; if all used, reuse with warning (eech group.c:1450-1494). Freed on group kill (eech group.c:1499-1524; called eech gp_dstry.c:300). Non-aircraft groups get callsign index = position within division (used as platoon number, eech division.c:492-495).

### GROUP-F11 — Divisions

- Division DB (all 17 rows, eech dv_dbase.c:79-252):

| Division sub-type (line) | full_name fmt | parent division type | max groups/div |
|---|---|---|---|
| AIRBORNE_HELICOPTER_DIVISION (dv_dbase.c:87) | "%s Airborne Division" | (none) | 0 |
| AIRBORNE_FIXED_WING_DIVISION (dv_dbase.c:97) | "%s Airborne Division" | (none) | 0 |
| AIRBORNE_TRANSPORT_DIVISION (dv_dbase.c:107) | "%s Airborne Division" | (none) | 0 |
| ARMOURED_DIVISION (dv_dbase.c:117) | "%s Armoured Division" | (none) | 0 |
| CARRIER_DIVISION (dv_dbase.c:127) | "%s Naval Division" | (none) | 0 |
| INFANTRY_DIVISION (dv_dbase.c:137) | "%s Infantry Division" | (none) | 0 |
| HC_ATTACK_COMPANY (dv_dbase.c:147) | "%s Aviation Group" | AIRBORNE_HELICOPTER_DIVISION | 0 |
| HC_TRANSPORT_COMPANY (dv_dbase.c:157) | "%s Transport Group" | AIRBORNE_TRANSPORT_DIVISION | 0 |
| FW_ATTACK_COMPANY (dv_dbase.c:167) | "%s Attack Squadron" | AIRBORNE_FIXED_WING_DIVISION | 0 |
| FW_FIGHTER_COMPANY (dv_dbase.c:177) | "%s Fighter Squadron" | AIRBORNE_FIXED_WING_DIVISION | 0 |
| FW_TRANSPORT_COMPANY (dv_dbase.c:187) | "%s Transport Squadron" | AIRBORNE_TRANSPORT_DIVISION | 0 |
| ADA_COMPANY (dv_dbase.c:197) | "%s SAM Brigade ADA" | ARMOURED_DIVISION | 0 |
| ARMOURED_COMPANY (dv_dbase.c:207) | "%s Armoured Brigade" | ARMOURED_DIVISION | 4 |
| ARTILLERY_COMPANY (dv_dbase.c:217) | "%s Artillery Brigade" | ARMOURED_DIVISION | 2 |
| CARRIER_COMPANY (dv_dbase.c:227) | "%s Carrier Task Force" | CARRIER_DIVISION | 0 |
| INFANTRY_COMPANY (dv_dbase.c:237) | "%s Infantry Brigade" | INFANTRY_DIVISION | 0 |
| SPECIAL_FORCES_COMPANY (dv_dbase.c:247) | "%s Special Forces Brigade" | INFANTRY_DIVISION | 0 |

  `maximum_groups_per_division == 0` means "unlimited" (vacancy check short-circuits, eech division.c:288-291,342-345).
- Hierarchy: force → division (e.g. Armoured Division) → company (e.g. Armoured Brigade, HQ'd at a keysite) → groups. `add_group_to_division` (eech division.c:149-398): picks the company type from group DB `default_group_division`; finds the HQ keysite — the keysite the group is parked at if AIRBASE/ANCHORAGE, else nearest carrier for sea groups, else nearest AIRBASE → MILITARY_BASE → FARP (eech division.c:205-274); reuses an existing company of that type at that HQ with a vacancy (limit = group DB `maximum_groups_per_division`), else finds/creates the parent division under the force (limit = division DB `maximum_groups_per_division`) and creates a new company under it (eech division.c:280-390).
- Division IDs come from campaign data (`FILE_TAG_DIVISION_ID_LIST` per side/type, eech parsgen.c:1524+ → `add_division_id_data`, eech division.c:726-745); IDs are handed out sequentially and wrap with a warning (eech division.c:751-788). ID pools are saved/restored (eech division.c:638-720).
- Naming (`set_local_division_name`, eech division.c:456-577): divisions format `full_name` with ordinal ("1st", "2nd" … special-case 11th/111th, eech division.c:404-450); groups format the group DB `platoon_name` by `platoon_id_type` — NUMBER = ordinal, LETTER = 'A'+index-1, CALLSIGN = group callsign, KEYSITE = HQ keysite name. A group's ordinal within its company is its list position (eech division.c:481-490).
- Divisions have no gameplay messages (handlers compiled out, eech dv_msgs.c:139-152) and no update function; they exist for naming, map organisation, and troop-drop bookkeeping (helicopter-dropped infantry groups joined to one division, eech mb_msgs.c:2466).

### GROUP-F12 — Regen entity lifecycle

- Regen entities are created during warzone population for every scene-link object at a keysite whose 3D model contains a `REGEN_*` sub-object (eech popread.c:3963-4070): category from `get_object_3d_regeneration_type` (eech regen.c:216-322); the regen is parented to the keysite (`LIST_TYPE_REGEN`) and to the **closest waypoint** (TAXI/NAVIGATION/LANDED) of the keysite's landing route for that category (eech popread.c:4025-4064). Its member is the regen building itself.
- Creation defaults: position mid-map until attributes set, alive, neutral side; initial `sleep = frand1() * 5.0 * ONE_MINUTE` (random 0-5 min stagger, eech rg_creat.c:162); linked into the global update list (eech rg_creat.c:188).
- Server tick (`update_server`, eech rg_updt.c:163-184): `sleep -= delta`; when `sleep <= 0` run `regen_update` and reset `sleep = regen_frequency[side] * get_regen_frequency_difficulty_modifier()`. The difficulty modifier is hardcoded to `REGEN_UPDATE_MEDIUM = 1.0` ("just use medium for now", eech regen.c:328-336; constants SLOW 1.5 / MEDIUM 1.0 / FAST 0.5 at eech regen.h:167-171).
- `regen_frequency[side]` is loaded from the campaign file (`FILE_TAG_REGEN_FREQUENCY`, float seconds, ASSERT > 0, eech parsgen.c:1500-1522 — DATA-DRIVEN; actual per-warzone values are in campaign data files, not the C source).

### GROUP-F13 — Regen queues (FIFO ring)

- Per side × per regen category ring buffer of `{type, sub_type, group}` (eech regen.c:99-103). Initialised to size `REGEN_QUEUE_DEFAULT_SIZE` and content -1 (eech rg_updt.c:892-922).

| Constant | Value | Source |
|---|---|---|
| REGEN_QUEUE_DEFAULT_SIZE | 5 | eech regen.h:149 |
| REGEN_QUEUE_MINIMUM_SIZE | 5 (= DEFAULT) | eech regen.h:151 |

- Insert (`regen_queue_insert`, eech rg_updt.c:763-814): write at `(front+count) % size`; if the queue is full, **advance front instead of growing count** — i.e. overflow silently overwrites the oldest pending regen.
- Consume (`regen_queue_use`, eech rg_updt.c:820-868): clear front element to -1, advance front, decrement count — **except** category PEOPLE, which returns early so the people queue never drains ("we want the regen queue always full", eech rg_updt.c:845-851).
- Resize (`increment_regen_queue_size`, eech rg_updt.c:955-1052): grows/shrinks by `shift`, floored at minimum size 5 (eech rg_updt.c:874-886), preserving up to `min(count, new_size)` oldest entries.
- Feeders — on server-side destruction, the dead unit's `(entity type, sub_type, group sub_type)` is queued for its own side: helicopters (eech hc_dstry.c:410-416), fixed wing (eech fw_dstry.c:368-374), routed vehicles (eech rv_dstry.c:369-375). **No ship or person destroy handler enqueues** (only those three call sites exist); `HACK_PEOPLE_INTO_REGEN_QUEUE` is compiled out (`#define ... 0`, eech rg_updt.c:78, dead block 924-948). `add_default_entity_to_regen_queue` queues the group DB default member sub-type for the side (eech rg_updt.c:728-757).

### GROUP-F14 — Regen update: gating & spawn

`regen_update` (eech rg_updt.c:199-589), in order:
1. Queue empty → nothing (rg_updt.c:256-259).
2. Regen building dead OR keysite `KEYSITE_USABLE_STATE != KEYSITE_STATE_USABLE` → nothing (rg_updt.c:265-276).
3. **Reserve gating**: look up the front element's force-info category in `aircraft_database` (fixed wing/helicopter) or `vehicle_database` (everything else) and read `force_info_reserve_hardware[category]`; `reserve_count <= 0` → nothing (eech rg_updt.c:285-297). (The reserve itself is decremented by the spawn via force-info accounting; remaining reserves are logged at rg_updt.c:523-536.)
4. **Player-landed veto**: if any non-AI member of any group at the keysite is LANDED, no regen at this keysite (eech rg_updt.c:311-339).
5. Apache-Havoc-warzone veto: in campaigns flagged `CAMPAIGN_REQUIRES_APACHE_HAVOC`, PEOPLE regens do nothing, and FIXED_WING regens skip groups whose landing type is `LANDING_FIXED_WING_TRANSPORT` (airport routes may be missing) (eech rg_updt.c:348-382).
6. Spawn: `create_landing_faction_members(keysite, member_type, group_type, 1, wp, &regen->position)` — creates a **new group** at the keysite with **one member** (eech rg_updt.c:399). That function (eech faction.c:778-957+) requires a landing entity of the group's landing type with a free, unreserved, unlocked landing site; creates the group as a KEYSITE_GROUP child and the member with `OPERATIONAL_STATE_TAXIING` at the regen building's position (eech faction.c:901-957).
7. Post-spawn fix-ups: frontline groups (`INT_TYPE_FRONTLINE`) get the closest side road node within 5 km as `INT_TYPE_ROUTE_NODE` (eech rg_updt.c:408-414); member doors closed, regen building loading doors opened with a 30.0 s timer (eech rg_updt.c:426-438); fixed-wing transports are re-homed to the nearest waypoint of the transport landing route (eech rg_updt.c:446-491); a guide is created on the landing task for the new member and the group attached (eech rg_updt.c:494-500).
8. `regen_queue_use` pops the element (except PEOPLE) (eech rg_updt.c:570).

So a regenerated unit **appears taxiing at the regen building of a usable friendly keysite**, in a brand-new single-member group of the original group's type, and immediately flies/drives its landing/entry route.

### GROUP-F15 — Keysite capture/loss adjustments to regen capacity

- On keysite destruction/loss (`destroy_keysite`), queue capacity shrinks: AIRBASE → helicopter queue -6 and fixed-wing queue -4; FARP → helicopter queue -2 (floored at 5) (eech keysite.c:1266-1282).
- On capture, capacity grows and the queue is **seeded** for the new owner (eech keysite.c:1481-1517): AIRBASE → helicopter +6 with 2× ATTACK_HELICOPTER, 2× RECON_ATTACK_HELICOPTER, 2× ASSAULT_HELICOPTER defaults queued, and fixed-wing +4 with 2× CLOSE_AIR_SUPPORT and 2× MULTI_ROLE_FIGHTER; FARP → helicopter +2 with 2× RECON_ATTACK_HELICOPTER. Capture also repairs up to 5 structures and sets the keysite to REPAIRING unless at full strength (eech keysite.c:1456-1475).

### GROUP-F16 — Regen category groupings (declared lists)

`rg_updt.c` declares per-category group-type lists: `helicopter_groups[6]` (RECON, ATTACK, ASSAULT, HEAVY_LIFT, MARINE_ASSAULT, MEDIUM_LIFT), `fixed_wing_groups[4]` (CARRIER_ATTACK, CARRIER_INTERCEPTOR, CAS, MULTI_ROLE_FIGHTER), `routed_vehicle_groups[4]` (PRIMARY/SECONDARY_FRONTLINE, ARTILLERY, MLRS), `ship_groups[2]` (FRIGATE, LANDING_CRAFT), with counts 6/4/**7**/2 (eech rg_updt.c:120-157). Note `routed_vehicle_groups_count = 7` does not match its 4-element array (latent bug); no other file references these arrays (grep of source tree), so they appear unused/dead.

## 4. Interactions

- **Force info / reserves**: group creation/kill add/remove group types from force info (eech gp_creat.c:247, gp_dstry.c:293); regen is gated on `force_info_reserve_hardware` per hardware category (eech rg_updt.c:285-297) — reserves themselves are set by campaign `FILE_TAG_HARDWARE_RESERVES` data and decremented by unit creation (force-info module, spec 0x).
- **Keysites**: groups park at keysites (`LIST_TYPE_KEYSITE_GROUP`); keysite supply stocks are drained by group rearm/refuel (GROUP-F5); keysite usability gates regen (GROUP-F14); keysite capture/loss resizes and seeds regen queues (GROUP-F15); fixed group members contribute to keysite strength (GROUP-F3).
- **Task generation** (`ai/taskgen`): consumes GROUP_MODE, sleep, minimum_idle_count, member counts, DB suitability to pick groups for tasks (GROUP-F4); tasks drive guides which drive members; task completion triggers RTB (GROUP-F8).
- **Frontline system**: PRIMARY/SECONDARY/ARTILLERY frontline flags mark which group types man the frontline; frontline groups get road route nodes; ground advance/retreat is negotiated between groups via `GROUND_FORCE_ADVANCE/RETREAT` messages (eech gp_msgs.c:411-964, covered by the frontline spec).
- **Supply/cargo system**: RESUPPLY_SOURCE_GROUP groups generate supply missions; transport group types (cargo/troop ai_stats) fulfil them.
- **Divisions**: purely organisational; group naming and campaign-screen grouping; troop drops reuse the carrier group's division (eech mb_msgs.c:2466).
- **Multiplayer**: all lifecycle operations are server-side with comms mirroring (create/destroy/kill remote paths in gp_creat.c/gp_dstry.c/rg_creat.c).

## 5. Port mapping

| Feature | Status | Note |
|---|---|---|
| GROUP-F1 group type database | NOT PORTED | Port uses its own DCS unit compositions instead of the EECH group DB. |
| GROUP-F2 group entity creation | NOT PORTED | Port spawns fresh DCS groups per task; no persistent group entities. |
| GROUP-F3 member management | NOT PORTED | No member lists/renumbering; DCS group objects are per-spawn. |
| GROUP-F4 modes/sleep/idle gating | NOT PORTED | No idle-pool assignment; tasks get fresh spawns. |
| GROUP-F5 supplies on landing/rearm sleep | PARTIAL | Port implements supply consume-on-spawn and recycle-on-RTB; the level-scaled rearm/refuel sleep formula and keysite stock draw are not reproduced as such. |
| GROUP-F6 amalgamation | NOT PORTED | No persistent idle groups to merge. |
| GROUP-F7 retaliation/assistance | NOT PORTED | Unit-level reaction is left to native DCS AI; force-level assistance requests not implemented. |
| GROUP-F8 return to base | PARTIAL | RTB exists as recycle-on-RTB (supply refund); EECH waypoint-truncation logic not ported. |
| GROUP-F9 death/disband/emergency transfer | NOT PORTED | Fresh spawns per task make group disband/transfer moot. |
| GROUP-F10 callsign pool | UNKNOWN | Not covered by the port summary. |
| GROUP-F11 divisions | NOT PORTED | Explicitly out of scope for the port. |
| GROUP-F12 regen entity lifecycle | PROXY | Port ties regen to keysites/bases directly rather than regen-building entities with waypoint links. |
| GROUP-F13 regen FIFO queues | PORTED (regen) | FIFO ring size 5 per rules; aircraft only — ground/sea/people queues not ported (ground handled by ground_forces standing companies). |
| GROUP-F14 regen update gating & spawn | PARTIAL (regen) | Reserve gating per rg_updt.c:287 ported; 60 s tick instead of data-driven per-side frequency; building-alive/player-landed/Apache-Havoc vetoes and taxi-spawn mechanics not reproduced. |
| GROUP-F15 capture/loss queue resize & seeding | UNKNOWN | Not covered by the port summary. |
| GROUP-F16 category group lists | NOT PORTED | Dead/unused data in EECH itself. |

## 6. Open questions

1. **Actual regen frequency values** — `regen_frequency[side]` comes from `FILE_TAG_REGEN_FREQUENCY` in warzone campaign data files, which are not in the C tree. If a campaign omitted the tag the zero-initialised frequency (eech regen.c:112-113) would make `regen_update` run every server frame; the parser asserts frequency > 0 only when the tag is present (eech parsgen.c:1513). The port's 60 s tick is an assumption, not a source-derived constant.
2. **Empty regen database** — `REGEN_DATA` has no fields and `regen_database` has an empty initialiser (eech rg_dbase.h:64-68, rg_dbase.c:79-82). Per-category regen timers/delays simply do not exist in EECH; anything claiming otherwise is folklore. Was there intended content that was cut?
3. **Dead alternate parser** — `ai/faction/parser.c` contains a second `FILE_TAG_REGEN_FREQUENCY` handler using an undefined symbol `regen_update_frequency` (eech ai/faction/parser.c:1382-1424); the file is not in `libfaction_a_SOURCES` (eech ai/faction/Makefile.am) and cannot link. Treated as dead code.
4. **Ships and people never regenerate in practice** — `ENTITY_SUB_TYPE_REGEN_SEA` and `_PEOPLE` queues exist, but no ship/person destroy handler enqueues (only hc/fw/rv, GROUP-F13) and the people-hack is compiled out; the people queue also never dequeues (rg_updt.c:845-851). Is people regen fed by any other path (e.g. save-game unpack)? None found in the searched tree.
5. **`routed_vehicle_groups_count = 7` vs 4 array entries** (eech rg_updt.c:123,145-151) — latent out-of-bounds if anything ever iterated with the count; no consumer found.
6. **Regen overflow semantics** — a full queue overwrites the oldest pending record (eech rg_updt.c:791-794), so heavy attrition permanently loses regen entitlements beyond 5 per category. Intentional throttle or bug? Port should decide explicitly.
7. **`minimum_idle_count` asymmetry** — blue-leaning types (ATTACK 2, RECON_ATTACK 3, FIGHTER/CAS/NAVY-ATTACK 1) hold back idle groups from tasking while all others are 0 (Table 2); interaction with per-side balance untested.
8. **WUT overrides** — `group_database` is mutable and overwritten by WUT config readers (eech gwutcfg.c:1541-1548, wutcfg.c:678-688); shipped WUT data may differ from the compiled-in defaults tabled here.
