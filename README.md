# ee-dcs

The Enemy Engaged: Comanche Hokum (EECH) dynamic campaign, ported to Lua and running live
inside DCS World multiplayer.

> **Getting a mission:** you don't build these by hand. The **Campaign Generator** —
> published at **https://ee-dcs.pages.dev/** ([source](web/README.md)) — is how missions are
> distributed: open the site, design a theatre on a real-world map, and download a
> ready-to-play `.miz` with this campaign baked in.

## What it is

This is a direct port of the EECH dynamic campaign into DCS mission scripting. There is no
hand-authored `.miz` behind it: the script boots onto an **empty Caucasus mission**,
discovers every airbase on the map, assigns them to two coalitions, and then spawns and
runs an entire AI-vs-AI war from Lua — strike packages, recon, reactive intercepts, a
standing ground frontline, a helicopter war, logistics, and a win condition. A human who
joins finds an ongoing campaign already in progress, not a scripted mission.

The port is faithful: each module corresponds to specific EECH C source files (fork:
https://github.com/flying-dice/eech_source_code, mirror `E:\eech_source_code`), and campaign
constants and formulas are lifted from that source.

## How the campaign loop works

- **Strength economy.** Each side's strength is a live census of the hardware it currently
  fields (mirrors EECH `force_percentage`). Losing bases and aircraft drives strength down;
  it is what the win condition watches.
- **Finite reserves + RTB recycle.** Each side has finite per-role hardware pools seeded
  from its owned bases. Every spawn *consumes* from the pool; when an AI aircraft returns to
  base it is *recycled* back into the reserve (a port reconstruction of `replace_into_force_info`
  — shipped EECH has zero callers of it, see the `supply.lua` header). Surviving production
  keysites (factory / refinery / port) accumulate crates that restock consumer keysites and
  convert surplus into reserve replacement, so killing an enemy factory genuinely starves it.
  Run the pools dry and that side can no longer mount those sorties.
- **State-driven campaign tempo.** EECH does not use elapsed-time early / mid / late phases.
  Task generation, escorts and reactions respond to objectives, threat, fog of war, available
  reserves, keysite condition and the configured campaign mode.
- **Fog of war + recon fork.** Per-base, per-side fog decays continuously and is lifted by
  friendly units in proximity. Strike tasks are FOW-gated: a fogged target does not get
  dropped — it spawns a **recon sortie** aimed at the sector so the fog actually lifts and
  the strike can follow. This is EECH's self-healing strike-vs-recon fork.
- **Reaction chains.** When an enemy strike/OCA/recon group is detected, defensive CAP and
  BARCAP scramble at the threatened base. Completed strikes trigger a BDA helicopter, whose
  result branches into follow-on OCA strikes, sweeps, or troop insertions — the EECH
  task-completed reaction chain.
- **Standing ground frontline.** One armoured company per frontline base advances toward
  the nearest enemy base and retreats when its own base falls, with occupancy deconfliction
  and reserve-drawn reinforcement. Neutralised bases are captured by troop insertion after
  sustained proximity.
- **The helicopter war is the core.** As in EECH, rotary-wing is the main event:
  anti-armour attack-heli sections hunt frontline ground groups, hunter-killer sections fly
  armed recon (engaging ground *and* air, including heli-vs-heli), and attack helis escort
  vulnerable troop-insertion flights.
- **Win criteria.** The campaign ends when one side captures all bases or reduces the
  enemy's strength to zero; a full debrief is broadcast in-game.

## Authoring a mission — the zone-based theatre

The theatre is **designed in the DCS Mission Editor using trigger zones**, mirroring how EECH builds a
warzone from terrain keysites (`popread.c`). You place **one zone per keysite**; at boot the campaign
reads every zone and builds the whole order of battle from them — sides, base roles, the economy, the
strike/capture targets, and the front. Nothing is hard-coded to a map.

### Every keysite zone carries three things

| Zone property | Sets | How it's read |
|---|---|---|
| **Colour** | the **side** | blue-dominant colour → BLUE, red-dominant → RED (set the zone colour in the ME) |
| **Name** | the **type** | name the zone **`<type>_<label>`**, e.g. `airbase_batumi` (the leading letters before the `_` select the type) |
| **Position** | the **location** | zone centre = keysite location; an `airbase` zone binds to the DCS airfield it covers |

Naming convention: **`<type>_<label>`** — the part before the first underscore is the keysite type
(case-insensitive), the rest is a free label: `airbase_batumi`, `farp_north`, `factory_kutaisi`,
`radar_ridge`. (A space or hyphen separator also works, e.g. `airbase batumi` or `airbase-1`.)

There are **no big BLUE/RED boxes** — each keysite is its own coloured zone, and the colour alone
decides its side. The **front** emerges wherever BLUE and RED keysites face each other.

### Keysite types (first word of the zone name)

| Keyword | EECH keysite (`ks_dbase.c`) | Bases aircraft? | Role |
|---|---|---|---|
| `airbase` | AIRBASE (LARGE) | **fixed-wing + heli** | The few fields fixed-wing flies from. Place the zone **over a real DCS airfield**. |
| `farp` | FARP (SMALL) | **helicopters only** | Forward heli base, spawned at the zone. The rotary war launches from these. |
| `factory` | FACTORY | no | **Produces AMMO.** Destroy it and the enemy can't rearm or replace losses. |
| `refinery` | OIL_REFINERY | no | **Produces FUEL.** |
| `port` | PORT | no | Produces fuel (coastal). |
| `radar` | RADAR / EWR | no | Real emitter — a **SEAD target** and detection node. |
| `depot` | SUPPLY_DEPOT | no | Ammo store (consumer target). |
| `fuel` | FUEL_DEPOT | no | Fuel store. |
| `power` | POWER_STATION | no | Strategic target. |
| `command` | COMMAND_POST | no | Strategic target. |

The label after the type is free (`airbase_batumi`, `farp_north`, `factory_batumi_works`).
Only **AIRBASE** and **FARP** base aircraft — every other type bases nothing; it is something you
**strike and capture**, not fly from.

### Rules

- A DCS airfield with **no `airbase` zone** over it is **excluded** from the campaign.
- Keep the nearest opposing airfields/FARPs **~50–100 km apart** — that's helicopter range and the
  width of the front. Closer = faster, more intense; further = fixed-wing starts to dominate.
- Fixed-wing (OCA / keysite strike / SEAD) can only launch from `airbase` zones; the whole rotary war
  (CAS / BAI / troop insertion) launches from the `farp` network. That balance is set purely by **how
  many of each you place.**

### Recommended balance (per side, for an EECH-scale ~260 km theatre)

| Keysite | Per side | Why |
|---|---|---|
| `airbase` | **1–2** | Fixed-wing is scarce in EECH. More than 2 and it becomes a fixed-wing air war. |
| `farp` | **3–6** | The rotary war's forward bases — the bulk of the air activity. |
| `factory` | 1–2 | Ammo economy. Defended; losing it cripples the side. |
| `refinery` / `port` | 1–2 | Fuel economy. |
| `radar` | 2–3 | SEAD targets + detection coverage. |
| `depot` / `fuel` | 2–4 | Consumer supply nodes near the front. |
| `power` / `command` | 1–2 | Strategic strike targets. |
| **total keysites** | **~12–20** | A dense, heli-primary network. |

**Rule of thumb:** helicopter bases (`farp`) should outnumber fixed-wing `airbase`s **~3 : 1**, and
producers (`factory`/`refinery`/`port`) should be **few and rear** — they're the enemy's lifeline, so
bombing them is how a side is strangled. Radar sits forward (SEAD bait); depots/fuel near the front.

### Designing a theatre — step by step

1. Open an **empty** mission on your map in the ME (no units needed — the campaign spawns everything).
2. For each airfield you want in play, draw a zone over it, name it `airbase_<name>` **or** `farp_<name>`,
   and **colour it blue or red**. Airfields you don't zone are left out.
3. Place the **producer and target keysites** (`factory`, `refinery`, `radar`, `depot`, …) across each
   side's territory — producers in the rear, radar/depots toward the front — each coloured to its side.
4. Arrange the two colours so the **nearest opposing bases sit ~50–100 km apart** across the intended
   front line.
5. Aim for the balance table above (few airbases, many FARPs, a couple of producers).
6. **Save, run the mission, inject the campaign** (`dev-loop` skill). The boot log prints the theatre
   it read (`theatre from zones: N airbases, M FARPs, K keysites`), and every base and keysite is
   labelled on the F10 map.

If **no keysite zones are found**, the campaign falls back to auto-generating an EECH-scale theatre
from the map's airfields (densest cluster) so it still runs on a bare map.

## Configuring the campaign (`DMT_CONFIG`)

The scenario **warzone data** — unit type names, countries, weapon payloads, reserve counts,
installation statics, keysite air-defence rings, and a few documented designer theatre knobs — lives in one place:
`packages/ee-mission/src/config.ts`. It mirrors EECH's own split between compiled engine
constants (in the C source) and the data files it loads from disk (FORMCOMP.DAT, the WUT tables):
`config.lua` is the **data layer**.

You can override any subset of it **without editing the script** by setting a global table
`_G.DMT_CONFIG` **before** the campaign loads.

### Where to put it

Add a **MISSION START → DO SCRIPT** trigger (or a `DO SCRIPT FILE`) that runs *before* the trigger
that loads `dist/ee-dcs.lua`. It only needs to assign the global:

```lua
-- MISSION START, ordered BEFORE the campaign DO SCRIPT FILE trigger
DMT_CONFIG = {
  -- Side-keyed tables use the STRING keys "blue" / "red" (NOT coalition.side numbers).
  types = {
    aircraft = {
      blue = { striker = "FA-18C_hornet" },   -- fly Hornets as the BLUE striker
      -- roles: striker, escort, recon, attack_heli, transport_heli, transport_fw, bda_heli
      red  = { transport_fw = "IL-76MD" },    -- fixed-wing resupply transport (airbase↔airbase)
    },
  },
  reserves = {
    per_base = { striker = 6 },               -- deeper striker pool = longer war
  },
  defenses = {
    -- Keysite AIR-DEFENCE RINGS (ports EECH popread.c population AAA/SAM placements). Each keysite is
    -- ringed with N LIGHT_SAM_AAA groups; N (a designer proxy for the map-population density) and the
    -- ring radius are set here, plus the per-side 2-unit group composition (arrays replace wholesale).
    groups_per  = { airbase = 4, farp = 1, installation = 1 },  -- heavier airbase rings; 0 opts a class out
    ring_radius = 2000,                                         -- metres from the keysite centre
    group = { red = { "2S6 Tunguska", "Strela-10M3" } },       -- RED ring = SA-19 + SA-13
    -- Population FIRING POINTS (ports EECH popread.c:1389-1439 building-scene GROUP_STATIC_INFANTRY):
    -- an even mix of MG infantry + MANPAD soldiers scattered inside each keysite footprint (within
    -- ring_radius). Counts are a designer proxy for population density; 0 opts a class out. These are
    -- NOT strike targets (frontline_flag NONE) but the MANPADs feed the air-defence map.
    firing_points = { airbase = 4, farp = 2, installation = 2 },
    mg     = { red = "Infantry AK" },          -- MG-post soldier per side (proxy for FIRING_POINT posts)
    manpad = { red = "SA-18 Igla manpad" },    -- INFANTRY_SAM MANPAD soldier per side
  },
  payloads = {
    -- a pylon list REPLACES the default wholesale (see "arrays" below)
    red = { striker = {
      { CLSID = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}", num = 3 },  -- fuel
      { CLSID = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}", num = 5 },  -- Kh-29T
    } },
  },
}
```

The merged, active configuration is exposed on `_G.DMT_ACTIVE_CONFIG` for inspection/debugging.

### How merging works

- Your table is **deep-merged over the defaults**: you only set the leaves you want to change; every
  sibling key keeps its default.
- **Arrays replace wholesale** — a slot list, a pylon list, or a unit list you supply *replaces* the
  default array entirely (they are never merged per-index, which would be confusing).
- **Side-keyed tables use string keys** `"blue"` / `"red"` in `DMT_CONFIG`. (Internally the campaign
  re-keys them to `coalition.side.BLUE` / `coalition.side.RED`.)

### Validation (bad values are caught at boot)

Before anything spawns, the campaign validates your config and **logs to `dcs.log`**:

- Every aircraft/ground **unit type** is checked against this DCS install's DB (`Unit.getDescByName`).
  A bad override is logged as `[dmt:config] INVALID: <path> = <value> … — using default` and **falls
  back to the default** (resilient boot).
- If a **default type itself is missing** (e.g. the AH-64D module isn't installed — those spawns would
  silently fail), you get a **loud warning on screen and in the log** naming the types and the fix
  (install the module, or place one such unit in the `.miz` to preload it).
- **Statics** (type/shape/category triples) and **payloads** (CLSIDs) can't be verified from the
  mission environment, so only their **structure** is checked; the values are spawn-time-verified.
- A summary line reports `validated: N unit types OK, M unknown, K user overrides applied`.

### What is NOT configurable (by design)

Anything traceable to the **EECH C source** — cadences, strike/repair/capture formulas,
`MINIMUM_EFFICIENCY`, escort thresholds, fog-of-war gates, damage fractions, spawn kinematics
(altitudes/speeds/fuel) — is **deliberately hardcoded** in its module with a `file:line` citation, per
the project's prime directive (faithful port, not game design). `config.ts` is the warzone-data layer
only; it does not expose engine constants.

## Modules

34 TypeScript modules in `packages/ee-mission/src/`, each headed with the EECH source it ports.
The table below names each module without its extension; the Lua baseline they were ported from
(`Scripts/ee-dcs/*.lua`) was deleted on 2026-09-21 and is retained in git history.

| Module | EECH source | Role |
|---|---|---|
| `campaign_state.lua` | `session.c`, `ss_updt.c`, `force.h`, `fc_funcs.c`, `imaps.c` | SESSION + per-side FORCE singleton; balance-of-power strength census |
| `keysite.lua` | `keysite.h`, `ks_funcs.c`, `ks_updt.c`, `sc_secfuncs.c` | airbase ownership / strength / capture; strike-target scoring |
| `supply.lua` | `force.c` (add/remove/replace_into_force), `parser.c`, `rg_updt.c` | finite per-side hardware reserve; spawn-decrement / RTB-recycle |
| `win_condition.lua` | `fc_updt.c`, `force.h`, `fc_funcs.c` | campaign-criteria scan; kill → attrition ledger |
| `attack_waves.lua` | `highlevl.c` (create_oca/keysite_strike), `reaction.c`, `suitable.c` | periodic fixed-wing ground-strike + OCA strike packages |
| `cas_bai_sead.lua` | `highlevl.c` (create_cas/bai/sead/oca_sweep/artillery) | CAS / BAI / SEAD / OCA-sweep / artillery generators + recon fork |
| `ground_forces.lua` | `highlevl.c` (advance_and_retreat), `order.c`, `group.h` | standing armoured frontline; base-to-base advance / retreat / reinforce |
| `troop.lua` | `highlevl.c` (troop_insertion / patrol) | heli troop insertion (capture proxy) + infantry base patrols |
| `transfer.lua` | `highlevl.c` (fixed_wing / helicopter_transfer) | inter-base airframe redistribution (supply proxy) |
| `reaction.lua` | `reaction.c` | task-assigned CAP/BARCAP + task-completed BDA / follow-on chains |
| `regen.lua` | `rg_updt.c`, `regen.h`, `regen.c` | dead-airframe FIFO regen queue (ring buffer, reserve-gated) |
| `keysite_repair.lua` | `ks_updt.c`, `en_suply.h`, `keysite.h` | ammo/fuel drain-or-resupply + structural repair + efficiency |
| `supply_flight.lua` | `fc_msgs.c` (response_to_force_low_on_supplies), `taskgen.c` (create_supply_task), `ts_dbase.c` (TASK_SUPPLY) | PHYSICAL resupply transports — flies a crate producer→consumer; shot down = crate lost |
| `imap.lua` | `imaps.c` | 4 influence-map layers (base-distance / air-def / surface-def / importance) |
| `fog_of_war.lua` | `sector.c`, `highlevl.h` | per-base per-side FOW decay + recon grant |
| `frontline.lua` | `ai_fline.c`, `highlevl.c` | frontline detection (Gabriel-graph base adjacency — parameter-free proxy for EECH's 3x3 sector neighbourhood) |
| `recon.lua` | `highlevl.c` (create_recon_task), `reaction.c` | recon overflight — the FOW self-heal fork |
| `installations.lua` | `keysite.h` + keysite_database | non-airbase keysites (depot / fuel / radar) as ground-strike-only targets |
| `heli_war.lua` | `highlevl.c`, `suitable.c`, `entity/helicopter/*` | shared attack-heli builders (`build_attack_heli`, `spawn_escort`); the rotary frontline fight is CAS/BAI — the invented anti-armour/hunter-killer schedulers were deleted in Cluster H |
| `map_overlay.lua` | `briefing.c` / `campaign_map.c`, `ai_fline.c` | F-10 campaign map (ownership, task arrows, columns, frontline) |
| `payloads.lua` | `he_funcs.c`, `fw_funcs.c` | verified DCS pylon / CLSID loadouts |
| `main.lua` | (port shim) | trigger entry point: spawn_queue install → reset.nuke → config validate → single game_loop.start → queue drain |
| `game_loop.lua` | `highlevl.c` (start_high_level_ai), `update.c`, `ss_updt.c`, `fc_updt.c` | orchestrator: registers all timers with period + offset |

## Architecture

**One singleton, many registries.** `campaign_state.lua` owns `M.S`, the single shared
state table. Every module reads and writes `S.*` directly — there is no message bus. On top
of `S` sit a handful of registries: the **task registry** (`active_tasks`, the backbone of
the reaction system), the **force-reserve pools** (finite, consume/recycle), the **FOW
store**, the **ground-groups** frontline registry, the **keysite** airbase map (`base_*`),
and the **installations** registry (`keysites[...]`, non-airbase targets). The influence-map layers now
live on `S` too (`S.imap.raw` / `S.imap.nrm`, moved there in Wave 1 so they are part of the
persistence surface); `imap.lua` holds module-local *references* into `S.imap`, and consumers
still read them only through `imap.get()`.

**Dependency layering.** `campaign_state` and `payloads` have no dependencies. Most systems
depend only on `campaign_state` (plus `keysite` / `supply` for spawners). `game_loop`
requires everything and wires it together; `main` requires `game_loop`. A few cycles
(`reaction` ↔ `attack_waves` / `troop` / `cas_bai_sead`) are broken with lazy in-function
`require`, so there is no hard load-time cycle.

**Scheduler.** `game_loop.start()` first runs synchronous state init, registers four world
event handlers (kill, regen-dead, supply-RTB, reaction), then registers ~23 periodic timers,
each with a period and an initial offset that staggers load — a direct mirror of EECH's
`start_high_level_ai()`. Representative cadences:

| System | Period | System | Period |
|---|---|---|---|
| FOW decay + recon scan | 30 s | ground keysite strike | 450 s |
| keysite repair, regen dequeue | 60 s | heli anti-armour | 480 s |
| imap layers, frontline rebuild | 120 s | hunter-killer, FW transfer | 600 / 900 s |
| troop insertion | 120 s | CAS, artillery | 900 s |
| troop patrol | 300 s | OCA strike / sweep, BAI | 1800 / 1200 s |

The full 23-row schedule with per-side BLUE/RED offsets is defined in
`packages/ee-mission/src/game_loop.ts` (`start()`), mirroring EECH `start_high_level_ai()`.

**Re-injection is safe.** `campaign_state` bumps a global generation counter each load;
every scheduled closure self-cancels when the generation changes, so the bundle can be
hot-reloaded mid-session without double-registering timers. This is per-process only —
state does not survive a server restart.

## Running it

**Requirements:** Node.js and the installed workspace dependencies for building; DCS World 2.9+
and DCS Studio for static analysis and live injection.

1. **Build.** Run `npm run build --workspace ee-mission` → produces root `dist/ee-dcs.lua`
   from the TypeScript sources in `packages/ee-mission/src`. Keep the build free of errors and
   warnings, then run DCS Studio `check` against the generated bundle before injection.
2. **Load it,** either:
   - **Inject** into a running mission — `dcs_eval` runs
     `net.dostring_in('server', 'dofile("<path>/dist/ee-dcs.lua")')`; or
   - **DO SCRIPT FILE** trigger in the mission editor pointing at
     `dist/ee-dcs.lua`.
3. **Watch it.** All logging is `env.info()` → `Saved Games/DCS/Logs/dcs.log`. Phase
   transitions, captures, and the final debrief are also broadcast in-game via
   `trigger.action.outText`, and the F-10 map shows ownership, frontline, and task arrows.

Run `npm test --workspace ee-mission` for differential checks against the retained Lua sources
and simulated five-minute and 35-minute campaign runs. These require Lua 5.1 on PATH, or
`LUA_BIN` pointing to its executable. They cover engine calling conventions, timers, spawning,
persistence and reinjection, including player protection. They do not replace DCS Studio
analysis or live mission validation. The Lua originals in `Scripts/ee-dcs` were deleted on 2026-09-21 once the port was validated against them; they remain in git history. Regression cover is now the golden fixtures in `packages/ee-mission/test/golden/`, recorded from that baseline. This note previously said they would remain until
the TypeScript bundle passes live validation; rebuilding them with lua-cargo overwrites the
same deployment bundle with the old source tree.

## Multiplayer status

Honest state of play:

- **AI-vs-AI campaign — feature-complete vs EECH** (goals 01 and 02). Every major EECH
  campaign system has a module, all adversarially reviewed, building clean. It has **not
  yet been live-validated** in a running mission over a soak — that is the first P0 item.
- **Player slots — provisioned.** `coalition.addGroup` can't create human-flyable slots at
  runtime, so the web generator instead **bakes them into the `.miz`**: 4 `TakeOffParkingHot`
  Client slots per aircraft type at every compatible airfield, on real parking spots (see
  *Human-flyable MP slots* below). Needs the per-terrain airbase/parking export.
- **Join-leave / persistence — not yet built.** There is still no player join/leave
  lifecycle handling and no persistence across server restarts. The economy already treats
  humans carefully at the edges (the supply and reaction handlers skip player units; humans
  lift fog of war and count in the strength census; an enemy AI can target them) — but
  deliberate player lifecycle integration is the remaining work.

## Human-flyable MP slots

The web generator bakes **4 `TakeOffParkingHot` Client slots per aircraft type at each
compatible airfield** (fixed-wing at AIRDROMEs, helicopters at AIRDROMEs + HELIPADs), on
real parking spots, into `coalition.<side>.country[].{plane,helicopter}` — the exact group
shape the Mission Editor writes for a Client aircraft. The aircraft types follow the
campaign config (or your `DMT_CONFIG` overrides); each side's slots go to airfields that
side owns under the drawn frontline.

A ramp slot needs per-airfield DCS data — the numeric `airdromeId` and each parking spot's
`Term_Index` / `Term_Type` / world x,z — which only DCS can supply. So slots appear only
for terrains whose airbase/parking data has been exported (see **Exporting a theatre from
DCS** below); a terrain without it still gets zones + campaign, just no slots. Big
transports are placed on open ramps, fighters on shelters/open, helicopters on
helipad/open; spots are never reused, and shortfalls are reported.

## Exporting a theatre from DCS

Each theatre the web tool offers is **one file** — `web/src/theatres/<Id>.geojson`, a
GeoJSON `FeatureCollection` holding the **TERRAIN** feature (map-extent polygon + a proj4
projection extracted from DCS + UTM + self-validation anchors) plus one **AIRBASE** point
per airfield (with numeric `airdromeId`) and one **PARKING** point per spot (`Term_Index` /
`Term_Type` / world x,z). DCS terrains are geographically warped relative to WGS84, so the
projection is derived from DCS's own `convertLatLonToMeters` — projected zones then land
exactly where DCS puts them. Everything is extracted **from DCS**, never hardcoded.

Bounds/projection and airbases/parking come from two different DCS Lua environments (the
GUI/hooks env has `terrain.GetTerrainConfig`; the mission env has `world.getAirbases`), and
neither has both. So **`tools/dcs-export/theatre-dump.lua` runs as a GUI hook**: it computes
the TERRAIN feature locally, pulls the airbases from the running mission with
`net.dostring_in` (which works in a stock, sanitized mission env — `world`/`Airbase`/`coord`
are never sanitized), and writes the combined `<Id>.geojson` with `io`. No
`MissionScripting.lua` change of any kind.

1. **Copy `theatre-dump.lua`** into your DCS write dir's `Scripts\Hooks\` folder.
2. Restart DCS, then load a mission on each terrain. ~4 s in, an in-mission alert names the
   file it wrote — by default `Saved Games\DCS.openbeta\<Id>.geojson`; copy it into
   `web/src/theatres/`. (Or set `OUT_DIR` in the file to write there directly.) Re-running
   just overwrites, so it's idempotent.

There is **no fallback**: bounds/projection come straight from `terrain.GetTerrainConfig` /
`convert*`. If the hooks env can't read that API, nothing is written (never
partial/approximate data). Rebuild the web app after the `.geojson` lands in
`web/src/theatres/` — the theatre appears in the picker automatically (the app globs that
folder) and its airfields carry the parking data that lets generated `.miz` files include
Client slots.

## Persistence (surviving a server restart)

`persist.lua` is the port's EECH `pack_session` analog: it saves a projection of the campaign
state singleton `S` through the **DCS Studio SQLite bridge** (`dcs_studio.sqlite`, reachable from
the mission env and sanitization-safe — the port uses **no** `os`/`io`/`lfs`) and restores it in
`game_loop.start()`. The store is SQLite rather than `dcs_studio.file` because the file API is
write-only; SQLite is the only bridge surface the mission env can read back. State is serialized
with a small pure-Lua table serializer (not JSON, so integer `coalition.side` keys round-trip) into
a versioned self-contained blob.

**Disabled by default** — every current hot-re-inject workflow is byte-for-byte unchanged. Enable it
only for a dedicated-server deployment:

```lua
DMT_CONFIG = { persistence = {
    enabled         = true,                -- turn save/restore on
    autosave_period = 300,                 -- seconds between background autosaves
    slot            = "default",           -- one campaign per slot name
    db_path         = "dmt_campaign.sqlite" -- SQLite file under lfs.writedir() (bridge-guarded)
} }
```

Saves fire on the autosave timer, on every **keysite capture**, and on the **win declaration**.

**What is restored:** base ownership / health / efficiency / ammo / fuel / last-strike, campaign
objectives, per-side strength, the per-base idle ledger, production accumulators (including crate
earmarks), regen queues, fog-of-war, pilot career records, keysite health (installations + airbase
asset clusters, with saved-dead author statics re-killed so the world matches), and the mobile
ground OOB (primary/artillery/secondary groups respawned from position+count summaries,
reserve-neutral).

**Documented divergences from EECH pack_session** (DCS cannot serialize live object handles):
- **In-flight sorties are not restored** — airborne missions died with the old process. Their tasks
  are dropped; unassigned demand regenerates within one generator cycle (EECH repacks the task tree;
  the port cannot, because tasks reference live DCS groups/builders).
- **Air-defence rings, firing points, patrols, installations and airbase scenery re-seed fresh** at
  boot via their own `init()` (exactly as at-boot), then keysite health is overlaid from the save.
  Scenery handles cannot be re-acquired by name, so scenery attrition is restored via the
  count-derived keysite health, not per-object handles.
- **Timer-relative values are rebased** (`start_time`, `base_last_strike`, regen `enqueued`) because
  `timer.getTime()` resets to 0 on a server restart.
- **Dropped as transient:** counter-battery TTL markers, per-flight supply-delivery state,
  in-flight landing-slot counts, and the task board (all reconstruct within a cycle).

If the `dcs_studio` bridge is not reachable from the mission env, persistence self-disables with a
single log warning and the campaign runs normally — it is never a spawn-path dependency.

## Credits & links

- **Enemy Engaged: Comanche vs Hokum** — the original dynamic campaign this ports.
  Open-source fork: https://github.com/flying-dice/eech_source_code
- **DCS Studio** — the IDE and MCP tooling that builds, checks, and injects this mod:
  https://gitlab.beluga-sirius.ts.net/flying-dice/dcs-studio
