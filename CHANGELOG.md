# Changelog

All notable changes to **dynamic-mission-test** — an EECH (Enemy Engaged: Comanche Hokum) dynamic
campaign ported to DCS World mission scripting.

## [0.2.0] — 2026-07-10

**Full-parity release.** Every EECH campaign mechanic in the shipped C source is now ported, cited,
and live-verified — no deferred systems remain (34 modules, 0 warnings; 37 files checked, no
findings). Bundle: `dist/dynamic-mission-test.lua`.

### Fidelity realignments (all traced to the C; 214-feature gap analysis in
### `goals/03-mp-server-playout/GAP-ANALYSIS-2026-07-09.md`)
- **Strike targeting** — the real `create_keysite_strike_tasks` rating (1·airdef + 4·reach +
  2·damage + 2·ratio, `highlevl.c:1109-1127`) reading the imap layers; recon-first fork for
  airbases; ratio/eff/dedup/FOW gates; one ranked scan for airbases + installations.
- **Echelon war** — CAS = frontline, **BAI un-starved** (second echelon by group type,
  `gp_int.c:389-392`); SEAD excludes frontline AA.
- **Capture on arrival** — the roll fires at the TROOP_CAPTURE waypoint with real
  members/losses (`mb_msgs.c:2260-2325`); defender backup insertions; captured bases keep their
  parked aircraft **for the captor** (`keysite.c:1375-1393`).
- **Combined-arms ground OOB** — FORMCOMP.DAT slot compositions (tanks/IFVs/organic AD/APCs),
  **SECONDARY logistics echelon** that follows the front, **SP artillery** that advances to
  standoff, fires, and draws **counter-battery** (reconnecting the SURFACE_DEFENCE imap).
- **Keysite defence** — popread AD rings (LIGHT_SAM_AAA per side), MG/MANPAD firing points,
  dormant-FARP activation (`keysite.c:507-568`), re-garrison + re-man on capture.
- **Physical resupply** — transports fly crates producer→consumer (closest-producer,
  `fc_msgs.c:756-800`; pick-up before drop-off; interceptable — a downed transport loses its
  crate). Two-tier fixed-wing fleet (C-130/C-17A · An-26B/IL-76MD) + Black Hawks/Mi-8s for FARPs.
- **Biased routing (croute.c)** — all air traffic flies valley-following, enemy-sector-avoiding,
  dispersed routes (AIR profile 5.0/0.5/1.0); no more kill corridors.
- **ETA assignment gate** (`group.c:294-328`, remaining-window), per-type idle reserves,
  2-ship airbase assaults, unusable-base half-tempo assignment, escort-by-threat.
- **Post-victory literal semantics** — the war continues after the banner (`fc_msgs.c:163` is
  only a re-award guard); invented survival mode / win criterion (d) / kill-proximity bleed /
  repair supply-gate all removed.

### New systems
- **`DMT_CONFIG` loader** — all scenario data (types, compositions, payloads, reserves,
  defences, theatre knobs) author-overridable from the mission, boot-validated against the live
  DCS DB with per-leaf fallback (catches bad type names before anything spawns).
- **Persistence** (default off) — full campaign snapshot/restore via the DCS Studio SQLite
  bridge; autosave + save-on-capture/win; survives server restarts.
- **MP/pilot spine** — functional F-10 *Request Mission* (a human takes a board task out of the
  AI pool), per-task briefings with bearing/range, debrief loop with mission scoring, Air Medal
  streaks, Purple Hearts, campaign medals; player task reservation; regen player-landed veto;
  under-attack CAP scrambles against human strikes; humans counted in force strength.
- **Campaign/skirmish cadence modes** (`highlevl.c:220-268`), per-side campaign stats (log +
  F-10), task-completion assessment, leak-proof F-10 task arrows, land-snap for every computed
  ground placement (no more units in the sea).

## [0.1.0] — 2026-07-07

First tagged release. An AI-vs-AI EECH campaign boots from Lua onto a DCS mission: bases are
discovered from the map (or authored via zones), all units spawn at runtime, and the EECH high-level
AI runs on staggered timers. Re-injection safe (generation guard) and self-resetting.

### Campaign systems (ported from EECH C source)
- **Strike war** — keysite (ground) strikes and OCA strikes at EECH cadences (`highlevl.c`), capped
  at `CREATE_KEYSITE_STRIKE_TASK_COUNT = 3` per cycle.
- **Reaction chain** — airbase strikes scramble **one CAP** (`ks_dbase.c`: airbase `requires_barcap =
  FALSE`; BARCAP is carrier-only).
- **Helicopter war = the front** — CAS and BAI fly as **attack-helicopter sections from FARPs**
  (`ts_dbase.c` `landing_types`: CAS/BAI are heli-eligible); fixed-wing (OCA / keysite strike / SEAD)
  launches only from the few airbases. The invented `anti_armour`/`hunter_killer` layer was retired.
- **Capture chain** — troop insertion, ground advance, ownership flip, re-garrison, frontline recompute.
- **Supply economy** — producer keysites (factory/refinery/port) feed crate deliveries + reserve
  replacement; bombing them starves the enemy.
- **Win conditions** — objectives held / no usable airbase / no combat helis (`fc_msgs.c`).
- Recon, SEAD, OCA sweep, transfer, artillery, imap layers, fog-of-war, the task board.

### Theatre authoring
- **Zone-based theatre (`README.md` → "Authoring a mission")**: place one ME trigger zone per
  keysite — **colour sets the side**, the **first word of the name sets the type** (`airbase`, `farp`,
  `factory`, `refinery`, `port`, `radar`, `depot`, `fuel`, `power`, `command`), the **centre sets the
  location**. The whole order of battle is read from these zones.
- **Auto-fallback** for bare maps: scopes to the densest EECH-sized (~260 km) airfield cluster and
  auto-classifies roles.
- **Base roles** — a couple of fixed-wing AIRBASEs per side + heli-only FOBs + forward FARPs
  (`ks_dbase.c` air-force-capacity), enforced via the per-base supply ledger.
- **Physical keysites** — building statics + EWR radar ground units (SEAD targets), verified spawn types.
- **F10 map labels** — every base (role/owner/health/idle) and keysite (type/owner/health).
- DCS **warehouses are readable** (aircraft stock per base) — OOB wiring is planned (see backlog).

### Tooling
- Builds via DCS Studio MCP (`lua-cargo build`) to `dist/dynamic-mission-test.lua`; **0 warnings**,
  clean `check`. Lua 5.1 compatible. `dev-loop` / `eech-fidelity` / `live-validation` skills.

### Known limitations / next
- Some endgame/pacing values are **tuned, not yet C-sourced** (snowball scaling, `STRENGTH_SURVIVAL`,
  capture-on-dispatch, the extra "military collapse" win condition, `MAX_ASSIGN_RANGE`,
  `CAPTURE_REPAIR_HEALTH`) — flagged to be traced back to the EECH source (prime directive).
- Zone-authored keysites are built and pass build/check but are **not yet live-verified** in a mission
  that uses `airbase`/`farp`/keysite zones.
- **Warehouse-driven OOB** (spawn from stocked types, decrement on launch) not yet wired.
- **Persistence** is per-process only; a server restart resets the campaign.
- MP-server playout (human slots/lifecycle) partially addressed (goal 03).
