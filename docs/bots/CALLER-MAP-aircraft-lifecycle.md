# Caller map — aircraft lifecycle (epic #17, package P0-a)

Read-only survey of every aircraft allocation / spawn / registration / release / recycle
path in `packages/ee-mission/src/*.ts`. Facts only, no fix proposals. All citations verified
by grep against the file at the stated line.

Scope read in full: `recon.ts`, `heli_war.ts`, `cas_bai_sead.ts`, `attack_waves.ts`,
`troop.ts`, `supply_flight.ts`, `reaction.ts`, `regen.ts`, `supply.ts`, `task_board.ts`,
`keysite.ts`, `spawn_queue.ts`, `farp_parking.ts`, `campaign_state.ts`. `spawn_diagnostics.ts`
skimmed (spawn-queue instrumentation only, no allocation logic — not tabulated).
`test/core-parity.lua` grepped for direct references to the functions below: none found by
name: the current regression net (`core-parity.lua`, `campaign-smoke.lua` at 310 s/2100 s
against `test/golden/`) exercises these paths only indirectly, through the running
campaign's emergent state, not via targeted unit assertions.

## Mechanism notes read before the table

- **`spawn_queue.ts`** intercepts `coalition.addGroup`/`addStaticObject` globally
  (`spawn_queue.ts:97-123`) and defers the real spawn into `S.spawn_queue`, drained
  4/tick every 1 s by `drain()` (`spawn_queue.ts:124-202`, scheduled at
  `spawn_queue.ts:203-230`). Every `coalition.addGroup` call in every module below is
  therefore **queued, not synchronous** — the returned "Group" is a lazy proxy
  (`spawn_queue.ts:38-96`) until drained.
- **`task_board.ts`** is the assignment engine used by most (not all) generators.
  `create_task()` (`task_board.ts:201-246`) pushes a `BoardTask` and, if `immediate`,
  calls `try_assign` synchronously; otherwise the periodic `tick()`
  (`task_board.ts:476-564`, cadence `ASSIGN_CADENCE` = 3 min, scheduled
  `task_board.ts:566-589`) sorts by priority×critical and calls `try_assign` per task.
  `try_assign` (`task_board.ts:248-421`) picks the best in-range owned base with
  `ks.slot_available(base) >= 1` and `supply.ledger(base, role) >= count + MIN_IDLE`,
  debits `supply.consume_base` (`task_board.ts:306`), invokes the task's `builder`, and
  on success reserves a keysite slot (`ks.reserve_slot`, `task_board.ts:316`) and
  registers the task if the builder didn't already (`task_board.ts:322-339`). On builder
  failure it refunds via `supply.recycle_base` (`task_board.ts:356`) and the task stays
  `UNASSIGNED` for retry until `EXPIRY[type]`.
- **Crediting/release is a global DCS-event side effect, not a per-caller call.**
  `supply.make_land_handler()` (`supply.ts:530-602`) is registered once as an
  `S_EVENT_LAND` handler; on any non-player group landing it releases the keysite slot
  (`keysite.release_slot`, `supply.ts:545`) and credits the ledger via
  `classify_role(groupName)` (name-prefix match, `supply.ts:119-125`) →
  `recycle_base`/`recycle_side` (`supply.ts:576-578`). This is why most builders below
  show "none (see make_land_handler)" in the Recycle/credit column — the builder itself
  does not register a bespoke recycle path; recycling happens by group-name convention.

## Caller table

| Path (module.function) | Trigger | Reserve debit | Group builder(s) | Spawn mechanism | Task registration | Keysite slot | Recycle/credit | Delayed callbacks | Citation |
|---|---|---|---|---|---|---|---|---|---|
| `recon.spawn_recon` → `buildRecon` | single-shot export, called by many reactive callers (`attack_waves`, `cas_bai_sead`, `troop`, `reaction`) | `board.create_task` debits 1 `recon` via `try_assign`/`task_board.ts:306` (board-managed, not in `buildRecon` itself) | `buildRecon` (1 group, 1 unit) | `coalition.addGroup` (queued) inside `buildRecon` | `cs.register_task` in `buildRecon` | reserved by board (`task_board.ts:316`) | none in module — `make_land_handler` on RTB | none | `recon.ts:57-195`, `recon.ts:199-240` |
| `heli_war.build_attack_heli` (board builder, role `cas`/`bai`) | called from `cas_bai_sead.createStrike` builder via `require` (`cas_bai_sead.ts:622-628`) | `SECTION_SIZE`=2 `heli` debited by board (`task_board.ts:306`) before builder runs | `build_attack_heli` (1 group, 2 units = 1 section) | `coalition.addGroup` HELICOPTER (queued), `heli_war.ts:249-251` | none inside `build_attack_heli` — relies on `try_assign`'s generic register (`task_board.ts:322-339`) | reserved by board | none in module — `make_land_handler` | none | `heli_war.ts:87-288` |
| `heli_war.spawn_escort` → `buildEscort` | single-shot export (never-replace list, `heli_war.ts:449`); called from `troop.buildInsert` and `supply_flight.buildSupplyFlight` | 1 `heli` via board | `buildEscort` (1 group, 1 unit) | `coalition.addGroup` HELICOPTER (queued), `heli_war.ts:415-417` | none in `buildEscort` — generic board register | reserved by board | none in module — `make_land_handler` | none | `heli_war.ts:290-476` |
| `cas_bai_sead.runCas`/`runBai`/`runSead` → `createStrike` (types `cas`/`bai`/`sead`) | scheduled generators (`schedule_cas/bai/sead`, periods `mode.SCHED.*`) | board-managed (1 `heli` for cas/bai via `build_attack_heli`, or SEAD via `strikeBuilder`) | `strikeBuilder` (SEAD only) or `heli_war.build_attack_heli` (cas/bai) | `coalition.addGroup` (queued) | `strikeBuilder`: none directly (generic board register); SEAD escort spawned inline (see next row) | reserved by board | none in module — `make_land_handler` | none for the strike itself | `cas_bai_sead.ts:609-640`, `cas_bai_sead.ts:729-749` |
| `cas_bai_sead.strikeBuilder` → `spawnSeadEscort` (SEAD-only, inline escort) | called synchronously inside `strikeBuilder` when `isSead` (`cas_bai_sead.ts:587-595`) | **bypasses task_board**: `supply.consume_base(baseName, "escort", count)` called directly (`cas_bai_sead.ts:287`) | `spawnSeadEscort` (1 group, N units, N = `cs.escort_count(...)`) | `coalition.addGroup` AIRPLANE (queued), `cas_bai_sead.ts:321-401` | **none** — no `cs.register_task` call for the escort group | **none** — no `reserve_slot` call | on spawn failure: `supply.recycle_base` (`cas_bai_sead.ts:413`); on success: none in module, relies on `make_land_handler` by name prefix `Escort-` | none | `cas_bai_sead.ts:277-422` |
| `cas_bai_sead.spawn_sead_against` | single-shot export (reaction chain, never-replace) | via `createStrike`→board | `strikeBuilder` | queued `coalition.addGroup` | generic board register | reserved by board | `make_land_handler` | none | `cas_bai_sead.ts:751-769` |
| `cas_bai_sead.spawn_bai_against` | single-shot export (reaction chain) | via `createStrike`→board | `heli_war.build_attack_heli` | queued `coalition.addGroup` | generic board register | reserved by board | `make_land_handler` | none | `cas_bai_sead.ts:770-779` |
| `cas_bai_sead.run_oca_sweep` → `buildSweep`/`createSweep` | scheduled (`schedule_oca_sweep`) or directed (reaction, `run_oca_sweep(side, logFn, targetName, targetPos)`) | 1 `escort` via board | `buildSweep` (1 group, 1 unit) | `coalition.addGroup` AIRPLANE (queued), `cas_bai_sead.ts:795` | `cs.register_task` explicitly in `buildSweep` (`cas_bai_sead.ts:894-901`) | reserved by board | none in module — `make_land_handler` | none | `cas_bai_sead.ts:781-983` |
| `cas_bai_sead.runArtillery` (`schedule_artillery`) | scheduled (`schedule_artillery`) | **none — no aircraft, no group spawn.** Sets `FireAtPoint` task on an existing owned artillery group | n/a | n/a (no `coalition.addGroup`) | n/a | n/a | n/a | none | `cas_bai_sead.ts:989-1071` |
| `attack_waves.runScheduledStrike("ground")` → `keysite.pick_targets` → `createStrikeTask`/`recon.spawn_recon` | scheduled (`schedule_keysite_strikes`) | `STRIKE_PACKAGE_SIZE`=2 `striker` via board | `buildStrikePackage` | queued `coalition.addGroup` AIRPLANE, `attack_waves.ts:274` | `cs.register_task` explicitly (`attack_waves.ts:308-317`) | reserved by board | none in module — `make_land_handler`; on spawn failure returns `undefined` (board refunds) | strike-damage callback at `+KEYSITE_TIME_ON_TARGET`/`+INSTALLATION_TIME_ON_TARGET` (`attack_waves.ts:319-344`) | `attack_waves.ts:216-442`, `attack_waves.ts:484-502` |
| `attack_waves.runScheduledStrike("oca")` → `createStrikeTask` | scheduled (`schedule_oca_strikes`) | same as above | `buildStrikePackage` | same | same | same | same | same | `attack_waves.ts:504-531` |
| `attack_waves.buildStrikePackage` → inline escort (2nd `coalition.addGroup` in the SAME builder call) | inline, when `escorts > 0` after the strike group spawns | **bypasses task_board**: `supply.consume_base(baseName, "escort", escorts)` called directly (`attack_waves.ts:370`) | inline escort block (1 group, `escorts` units) | `coalition.addGroup` AIRPLANE (queued), `attack_waves.ts:394-409` | **none** — no `cs.register_task` for the escort | **none** — no `reserve_slot` call | on failure: `supply.recycle_base` (`attack_waves.ts:431`); on success: none in module, relies on `make_land_handler` by name prefix `Escort-` | none | `attack_waves.ts:370-440` |
| `attack_waves.run_strike` / `run_oca_strike` → `runSingle` → `createStrikeTask` | **single-shot exports — never-replace list** (reaction chain, `CLAUDE.md`) | same as scheduled path | `buildStrikePackage` (+ inline escort) | same | same | same | same | same | `attack_waves.ts:583-637` |
| `troop.runInsertion` → `createInsert` → `buildInsert` | scheduled (`schedule_troop_insertion`) or directed (reaction `run_troop_insertion(side, logFn, base)`) | `members` count (1 or 2, `AIRBASE_INSERT_TRANSPORT_COUNT`/`STANDARD_INSERT_TRANSPORT_COUNT`) `transport` via board | `buildInsert` (1 group, `members` units) | `coalition.addGroup` HELICOPTER (queued), `troop.ts:276-280` | `cs.register_task` explicitly (`troop.ts:282-289`) | reserved by board | none in module — `make_land_handler`; but see TTL row below | TTL clear at `+INSERT_TTL_SECONDS` (45 min): if task still registered, `cs.clear_task` + `keysite.release_slot` (`troop.ts:290-301`) — **does NOT recycle the transport ledger** (no `supply.recycle_base` call in that callback) | `troop.ts:164-329`, `troop.ts:479-486` |
| `troop.buildInsert` → conditional `heli_war.spawn_escort` | inline, when `cs.escort_count("troop_insertion", ...) > 0` (`troop.ts:302-305`) | via `heli_war.spawn_escort`'s own board task (1 `heli`) | `buildEscort` | queued `coalition.addGroup` | generic board register | reserved by board | `make_land_handler` | none | `troop.ts:302-305` |
| `troop.checkArrivals` — capture roll on proximity | scheduled inside `schedule_troop_insertion` tick, before `runInsertion` | **none (capture roll, not spawn)** | n/a | n/a | `cs.clear_task` (`troop.ts:160`) | `keysite.release_slot` (`troop.ts:161`) | n/a | none | `troop.ts:123-163` |
| `troop.spawnPatrol` (`schedule_patrol`) | scheduled, per owned base | **no aircraft** — ground infantry group | n/a | `coalition.addGroup` GROUND (queued), `troop.ts:424` | none | none | none | none | `troop.ts:384-478` |
| `supply_flight.request` → `buildSupplyFlight` | called from `supply.ts` consumption logic (not in this file's scope) when a keysite is low; `has_pending` dedup gate | 1 `transport` via board; crate earmarked via `supply.earmark_crate` (`supply_flight.ts:525`) BEFORE task creation, released on spawn success (`supply_flight.ts:430`) | `buildSupplyFlight` (1 group, 1 unit) | `coalition.addGroup` (AIRPLANE or HELICOPTER by base kind, queued), `supply_flight.ts:426-428` | `cs.register_task` explicitly (`supply_flight.ts:431-441`) | reserved by board | on spawn failure: `supply.refund_crate` (`supply_flight.ts:481`); on success handled by backstop timer (next row) | `scheduleBackstop` (`supply_flight.ts:159-187`) — a TTL based on route distance / 40 m/s + 10 min; on fire it force-recycles the transport ledger (`recycleSupplyOnce`→`supply.recycle_base`, `supply_flight.ts:150,178`), releases the slot, destroys the group and clears the task **even if the flight is still alive/flying** | `supply_flight.ts:189-493`, `supply_flight.ts:495-560` |
| `supply_flight.buildSupplyFlight` → conditional `heli_war.spawn_escort` | inline, when `cs.escort_count("supply", ...) > 0` (`supply_flight.ts:442-446`) | via `heli_war.spawn_escort`'s own board task | `buildEscort` | queued `coalition.addGroup` | generic board register | reserved by board | `make_land_handler` | none | `supply_flight.ts:442-446` |
| `supply_flight.scanSide` (`check_arrivals`/`schedule_arrivals`) | periodic scan, 20 s (`ARRIVAL_SCAN_PERIOD`) | **none — proximity check only**, marks `S.supply_delivered[groupName]` and restocks base ammo/fuel | n/a | n/a | n/a (reads `cs.get_task`) | n/a | n/a (restock happens here; airframe recycle happens on landing via `make_land_handler` or the backstop TTL) | none | `supply_flight.ts:562-667` |
| `reaction.reactOffense` → `spawnCap` (CAP/BARCAP) | S_EVENT_BIRTH handler (`make_event_handler`) when an offensive task (ground_strike/oca_strike/oca_sweep/recon) is born against a keysite requiring CAP/BARCAP | 1 `escort` — **direct `supply.consume_base` call, NOT task_board** (`reaction.ts:317`) | `spawnCap` (1 group, 1 unit) | `coalition.addGroup` AIRPLANE (queued), `reaction.ts:328` | `cs.register_task` explicitly (`reaction.ts:359-365`) | `keysite.reserve_slot` explicitly (`reaction.ts:358`) — **bypasses task_board's slot reservation path** | on spawn/base failure: `supply.recycle_base` (`reaction.ts:320,355`); on success: recycled only by the expiry timer below (no `make_land_handler` reliance since CAP never physically lands before being destroyed) | `expireCap` (`reaction.ts:290-309`) at `+duration` (1800 s normal, 900 s under-attack): `recycleOnce`→`supply.recycle_side` (`reaction.ts:213-220,300`), `keysite.release_slot`, `group.destroy()`, `cs.clear_task` | `reaction.ts:310-399` |
| `reaction.on_keysite_under_attack` → delayed `spawnCap` | called externally (not in scope files — presumably `keysite.ts` damage path) on a keysite taking damage | same as `spawnCap` above, but only fires after `UNDER_ATTACK_RESPONSE_DELAY_SECONDS` (60 s ± 20 s jitter) and a per-base cooldown gate (`S.keysite_assist_timer`) | `spawnCap` | queued `coalition.addGroup` | same | same | same (`UNDER_ATTACK_CAP_DURATION_SECONDS` = 15 min instead of 30) | delayed scheduled call itself (`reaction.ts:418-431`), then `expireCap` inside `spawnCap` | `reaction.ts:401-432` |
| `reaction.createSeadRing` → `cas_bai_sead.spawn_sead_against` (up to `MAX_KEYSITE_SEAD_TASKS`=3) | called from `reactReconKeysite` when a keysite recon/BDA/strike completes | delegated to `cas_bai_sead.spawn_sead_against`/board | delegated | delegated | delegated | delegated | delegated | none directly | `reaction.ts:434-464` |
| `reaction.spawn_bda` | **single-shot export (never-replace list)**; called from `reactStrike` when a target base is below minimum efficiency and `recon_target` | 1 `heli` — **direct `supply.consume_base` call, NOT task_board** (`reaction.ts:554`) | inline builder (1 group, 1 unit) | `coalition.addGroup` HELICOPTER (queued), `reaction.ts:623-627` | `cs.register_task` explicitly (`reaction.ts:633-640`) | `keysite.reserve_slot` explicitly (`reaction.ts:632`) — bypasses board | on spawn/base failure: `supply.recycle_base` (`reaction.ts:558,629`) | loiter timer at `+BDA_LOITER_SECONDS` (3 min): re-runs `reactReconKeysite` (chains into further strike/OCA/T.I. reaction), then `recycleOnce`→`supply.recycle_side`, `keysite.release_slot`, `group.destroy()`, `cs.clear_task` (`reaction.ts:641-654`) | `reaction.ts:547-655` |
| `reaction.on_artillery_fire` | called from `cas_bai_sead.runArtillery` per successful artillery task assignment | delegated to `cas_bai_sead.spawn_bai_against` (BAI, high FOW) or `recon.spawn_recon` (low FOW) | delegated | delegated | delegated | delegated | delegated | dedup TTL `COUNTER_BATTERY_TTL_SECONDS` (20 min) tracked in `S.counter_battery`, no group spawned by this function itself | `reaction.ts:658-705` |
| `reaction.make_event_handler` (`S_EVENT_LAND` branch) | every group landing | none directly — dispatches to `reactStrike`/`reactReconGroup`/`reactReconKeysite` which each debit their own reserve as tabulated above | n/a | n/a | n/a — but does `cs.clear_task(name)` after dispatch (`reaction.ts:766`) | **does not call `keysite.release_slot` itself** — relies on `supply.make_land_handler` (registered separately) to do so on the same S_EVENT_LAND | `cs.assess_task`/`cs.stat_task_result` bookkeeping only | none | `reaction.ts:716-783` |
| `reaction.make_event_handler` (`S_EVENT_DEAD` branch) | every unit death | none — only clears the task record if the whole group is gone (`reaction.ts:772-779`); actual reserve/regen bookkeeping on death lives in `regen.make_dead_handler`, a separate handler not called from here | n/a | n/a | `cs.clear_task` | not touched here (dead-unit slot release is `regen.make_dead_handler`, `regen.ts:264`) | none | none | `reaction.ts:767-779` |
| `supply.make_land_handler` (S_EVENT_LAND, global) | every non-player group landing | **credits** — `classify_role(groupName)` by name-prefix (`supply.ts:119-125`) then `recycle_base`/`recycle_side` for `survivorCount` units (`supply.ts:576-578`) | n/a | n/a | n/a | `keysite.release_slot(groupName)` unconditionally, even for unclassified/roleless groups (`supply.ts:545`) | **this is the primary credit path** for every builder above that has no bespoke recycle in its own module | schedules `group.destroy()` after `LANDED_GROUP_CLEANUP_DELAY_SECONDS` (`supply.ts:592-599`) | `supply.ts:530-602` |
| `regen.make_dead_handler` (S_EVENT_DEAD, global) | every non-player unit death | none — no ledger credit on death (aircraft is lost); instead enqueues a **replacement** request | n/a | n/a | n/a | `keysite.release_slot(groupName)` if the whole group is now dead (`regen.ts:264`) | n/a — this is a loss, not a credit | enqueues into `S.regen_queue[side][role]` (ring buffer, oldest evicted on overflow, `regen.ts:165-183`); consumed later by `spawnRegen`/`processQueue` | `regen.ts:221-332` |
| `regen.spawnRegen` (`schedule_regen`, periodic drain of `S.regen_queue`) | scheduled (`REGEN_PERIOD`), gated by base health ≥ neutralised threshold, `supply.available(base, role) > 0`, and no player landed nearby (`playerLandedAt`) | `supply.consume(baseName, role, 1)` = `consume_base` (`regen.ts:412`) — **permanently debits the ledger; the spawned group is never registered as a task, never lands, and is never recycled back** (parked idle representation) | inline builder (1 group, 1 unit, no route beyond Depart) | `coalition.addGroup` (queued), `regen.ts:478` | **none** — no `cs.register_task` | **none** — no slot reservation | **none** — this group is the credit; it sits parked, outside the task/slot/ledger bookkeeping entirely once spawned | none | `regen.ts:334-527` |
| `keysite.do_capture` → `reseedRegenOnCapture` | called from `troop.checkArrivals` on a won capture roll | `supply.recycle_side(newSide, "heli"/"striker", CAPTURE_REGEN_*)` credits the new owner; `supply.consume_side(oldSide, ...)` shrinks the old owner's reserve by the same counts (`keysite.ts:863-876`) | n/a (no group spawned here) | n/a | n/a | n/a | this function **is** a credit/debit pair, no group | queues `regen.queue_reseed` (adds entries to `S.regen_queue[newSide]`, consumed later by `spawnRegen`) | `keysite.ts:856-888` |
| `keysite.do_capture` — parked-aircraft ledger transfer | same call | `S.base_ledger[baseName]` (existing parked-aircraft counts) is **kept as-is** under the new owner — no debit/credit, ownership of the ledger table itself transfers with the base (`keysite.ts:916-927`) | n/a | n/a | n/a | n/a | n/a — documented as faithful to `keysite.c:1375-1393 command_line_capture_aircraft=TRUE` | none | `keysite.ts:916-927` |
| `keysite.do_capture` — task termination | same call | terminates (does not credit) every active task and every UNASSIGNED board task targeting the captured base (`keysite.ts:930-951`) | n/a | n/a | `cs.clear_task` for each doomed group | not released here — relies on `make_land_handler`/expiry timers on the now-doomed groups | n/a | none | `keysite.ts:929-951` |

## Paths that spawn MORE THAN ONE group per call

- `cas_bai_sead.strikeBuilder` (SEAD) — 1 strike group + (inline, same call) `spawnSeadEscort` 1 escort group. `cas_bai_sead.ts:587-595`.
- `attack_waves.buildStrikePackage` — 1 strike group (2 units) + (inline, same call) 1 escort group when `escorts > 0`. `attack_waves.ts:370-440`.
- `troop.buildInsert` — 1 transport group + (inline, same call, via `heli_war.spawn_escort`) 1 heli-escort group when `escort_count > 0`. `troop.ts:302-305`.
- `supply_flight.buildSupplyFlight` — 1 supply transport + (inline, same call, via `heli_war.spawn_escort`) 1 heli-escort group when `escort_count > 0`. `supply_flight.ts:442-446`.
- Note: `heli_war.build_attack_heli` spawns exactly ONE group containing 2 units (a "section", `SECTION_SIZE=2`) — this is one `coalition.addGroup` call, not two separate groups. `heli_war.ts:60,122-142`.

## Paths that bypass task_board entirely

- `cas_bai_sead.spawnSeadEscort` — direct `supply.consume_base`/`recycle_base`, no `board.create_task`, no `cs.register_task`, no `keysite.reserve_slot`. `cas_bai_sead.ts:277-422`.
- `attack_waves.buildStrikePackage`'s inline escort block — same pattern, direct `supply.consume_base`/`recycle_base`, no task registration, no slot reservation. `attack_waves.ts:370-440`.
- `reaction.spawnCap` (CAP/BARCAP) — direct `supply.consume_base`/`recycle_base`, but DOES call `cs.register_task` and `keysite.reserve_slot` explicitly (its own bespoke bookkeeping, not the board's). `reaction.ts:310-399`.
- `reaction.spawn_bda` — same pattern as `spawnCap`: direct `supply.consume_base`, own `cs.register_task`/`keysite.reserve_slot`. `reaction.ts:547-655`.
- `regen.spawnRegen` — direct `supply.consume` (=`consume_base`), no task registration, no slot reservation, no board involvement at all; the spawned group is a permanent, unmanaged parked unit. `regen.ts:334-505`.
- `troop.spawnPatrol` — no reserve system involved (ground infantry, not aircraft), no board. `troop.ts:388-473`.
- `cas_bai_sead.runArtillery` — no group spawn (re-tasks an existing artillery group). `cas_bai_sead.ts:989-1071`.

## Places that credit force reserve or release a keysite slot

| Location | Trigger evidence | What it does |
|---|---|---|
| `supply.make_land_handler` | `S_EVENT_LAND` (global handler) | `keysite.release_slot` unconditionally; `recycle_base`/`recycle_side` for survivor count, role from group-name prefix (`classify_role`) | `supply.ts:530-602` |
| `regen.make_dead_handler` | `S_EVENT_DEAD` (global handler) | `keysite.release_slot` if whole group now dead; NO ledger credit — enqueues a regen request instead | `regen.ts:221-332` |
| `reaction.expireCap` (inside `spawnCap`) | fixed-duration `timer.scheduleFunction` (1800 s / 900 s), not a DCS event | `supply.recycle_side`, `keysite.release_slot`, `group.destroy()`, `cs.clear_task` — fires even if the CAP group is still alive and flying | `reaction.ts:290-309` |
| `reaction.spawn_bda`'s loiter callback | fixed-duration timer (`BDA_LOITER_SECONDS`=180 s) | same recycle/release/destroy/clear pattern as `expireCap` | `reaction.ts:641-654` |
| `troop.buildInsert`'s TTL callback | fixed-duration timer (`INSERT_TTL_SECONDS`=2700 s), only if task is still registered | `cs.clear_task` + `keysite.release_slot` — **does not call `supply.recycle_base`**, so a timed-out insertion never returns its `transport` reserve slot to the ledger | `troop.ts:290-301` |
| `supply_flight.scheduleBackstop` | route-distance-derived timer (`routeDistance/40 + 600s`) | force-recycles transport ledger, releases slot, destroys group, clears task — fires even if the flight is still alive, same pattern as `expireCap` | `supply_flight.ts:159-187` |
| `troop.checkArrivals` | proximity to own registered `target_base` (radius 8000 m) on `Insert-*` groups | `cs.clear_task`, `keysite.release_slot` on capture-roll resolution (win or lose); no ledger credit (transport recycled later by `make_land_handler` on its RTB leg, if it survives) | `troop.ts:123-163` |
| `keysite.reseedRegenOnCapture` (inside `do_capture`) | won capture roll | `recycle_side(newSide, ...)` credits fixed `CAPTURE_REGEN_HELI`/`CAPTURE_REGEN_FW` counts; `consume_side(oldSide, ...)` debits the same counts from the old owner | `keysite.ts:856-888` |
| `task_board.try_assign` builder-failure branch | `pcall` around `task.builder(bestBase)` returning `undefined` or throwing | `supply.recycle_base` refunds the count debited at the top of the same call | `task_board.ts:356` |
| Per-builder spawn-failure branches (recon has none; heli_war/attack_waves/cas_bai_sead/troop/supply_flight/reaction each have their own) | `coalition.addGroup` (via the queue) returning `undefined`, or a missing `Airbase`/base_pos | `supply.recycle_base`/`refund_crate` inline in the builder, immediately | see individual rows above |

## Open questions for Lead

- `troop.buildInsert`'s TTL path (`troop.ts:290-301`) clears the task and releases the
  keysite slot but never calls `supply.recycle_base`/`recycle_side` for the `transport`
  role — is that an intentional "lost in the field" model (matching a shot-down/never-
  landed insertion) or a gap, given every other timeout path (`expireCap`, BDA loiter,
  supply backstop) does recycle?
- `regen.spawnRegen` permanently debits the ledger and spawns an unmanaged, un-registered,
  parked group with no route beyond the takeoff waypoint — it never re-enters the
  task/slot/ledger system. Is this intended to represent "idle parked inventory" for good,
  or is a later mechanism (not in the read scope) expected to pick these up (e.g. task_board
  treating them as available stock some other way)?
- `reaction.spawnCap`/`reaction.spawn_bda` both bypass `task_board` and hand-roll their own
  `supply.consume_base` + `cs.register_task` + `keysite.reserve_slot`. Is this deliberate
  (matching `reaction.c`'s direct dispatch, per the module header) or an artifact of
  `task_board` not existing/being retrofitted after `reaction.ts` was written?
- `cas_bai_sead.spawnSeadEscort` and `attack_waves.buildStrikePackage`'s inline escort spawn
  neither register a task (`cs.register_task`) nor reserve a keysite slot — they rely solely
  on `make_land_handler`'s name-prefix (`Escort-`) recycling on RTB. Is the missing
  `reserve_slot` for these escorts intentional (uncapped inline escorts) or an oversight
  relative to `reaction.spawnCap`'s CAP escorts, which do reserve a slot?
- I did not read `pilots.ts`, `ground_forces.ts`, `keysite.ts` (in full), `installations.ts`,
  `frontline.ts`, `win_condition.ts`, `base_defenses.ts`, `persist.ts`, `croute.ts`,
  `fog_of_war.ts`, `imap.ts`, or `config.ts` — several of the above rows `require()` into
  them (e.g. `pilots.reserve_side` for player-flown sorties, `keysite.pick_targets`/
  `strike_candidates` target selection, `base_defenses.regarrison`, `installations.damage`/
  `nearest_producer`). If epic #17 needs those paths mapped too, that is a separate package.
- I could not fully trace the caller of `supply_flight.request` (which module invokes it
  when a keysite goes low) since that caller lives outside the scoped file list — worth
  confirming which module (likely `supply.ts`'s low-supply detection, not shown here) drives
  it and at what cadence.

## Lead answers (2026-09-22, verified)

- **Q5 — out-of-scope modules.** Checked: `grep -n "consume_side|consume_base|recycle_side|recycle_base"`
  over `pilots.ts ground_forces.ts base_defenses.ts installations.ts frontline.ts` returns hits in
  `ground_forces.ts` only (lines 266, 273, 294, 375, 386, 389, 430, 485, 497) and **every one is role
  `"vehicle"`**. No aircraft role is debited or credited outside the mapped files. The caller map is
  complete for epic #17; no follow-up survey package is needed.
- **Q6 — `supply_flight.request` caller.** `grep -rn "supply_flight" --include=*.ts` outside the module
  itself returns exactly two importers: `game_loop.ts:55` (scheduling) and **`keysite_repair.ts:41`**,
  which is the low-supply/repair driver. Cadence is `keysite_repair`'s own scheduler entry.
- **Q1–Q4 (troop TTL not recycling `transport`; `regen` permanent debit; `reaction` hand-rolled
  bookkeeping; inline escorts reserving no slot)** are **deferred to P1/P3, not answered here.** Each
  is a candidate divergence, and under the Prime Directive the answer must come from the EECH C source
  (`assign.c`, `reaction.c`, `ld_msgs.c`), not from a judgement about internal consistency. They are
  recorded as P1/P3 inputs in sprint 04; do not "fix" any of them on consistency grounds alone.

## P4 integration status (2026-09-23)

Compiled by **Lead** from the post-P4 source, not from the bot's report — the P4 agent stalled
at the Biome gate before writing this section. Every row below was confirmed by grep against
`packages/ee-mission/src` at the stated line.

Note the API is `retire_sortie(groupName, reason, outcome)`, not the `resolve_sortie` name used
in the P4 brief; the brief's name was provisional.

| Path | Status | Owner mechanism | Evidence |
|---|---|---|---|
| All `task_board` builder paths (recon, heli CAS/BAI, SEAD strike, OCA sweep, strike packages, troop insert, supply flight) | **On contract** | `begin_allocation` → builder → `commit_allocation` | `task_board.ts:367`, `task_board.ts:426` |
| `recon.buildRecon` | On contract | `aircraft.track(group)` under the board allocation | `recon.ts:164` |
| `heli_war.build_attack_heli` | On contract | `aircraft.track(group)` | `heli_war.ts:257` |
| `attack_waves.buildStrikePackage` + **inline escort** | **On contract** (was a bypass) | nested `begin_allocation` at :380, escort `track` at :428, `commit_allocation` at :430 | `attack_waves.ts:380,428,430` |
| `cas_bai_sead.spawnSeadEscort` | **On contract** (was a bypass) | `begin_allocation` :306, `track` :419, `commit_allocation` :421 | `cas_bai_sead.ts:306,419,421` |
| `reaction.spawnCap` | **On contract** (was hand-rolled) | `begin_allocation` :327, `track` :366, `commit_allocation` :382, `abort_allocation` :368 | `reaction.ts:327,366,368,382` |
| `reaction.spawn_bda` | **On contract** (was hand-rolled) | `begin_allocation` :642, `track` :678, `commit_allocation` :693, `abort_allocation` :667,:680 | `reaction.ts:642,667,678,680,693` |
| `regen.spawnRegen` | **On contract** (was a bypass) | `begin_allocation` :508, `track` :553, `commit_allocation` :555 | `regen.ts:508,553,555` |
| `troop.buildInsert` | On contract | `lifecycle.track(group)` | `troop.ts:285` |
| `supply_flight.buildSupplyFlight` | On contract | `lifecycle.track(group)` guarded on `spawned` | `supply_flight.ts:453` |
| `reaction.expireCap` (virtual retirement, 1800/900 s) | **Settles through contract** | `retire_sortie(name, "CAP station time expired", "recycled")` | `reaction.ts:299` |
| `reaction.spawn_bda` loiter (180 s) | **Settles through contract** | `retire_sortie(name, "BDA loiter complete", "recycled")` | `reaction.ts:701` |
| `supply_flight.scheduleBackstop` (route/40 + 600 s) | **Settles through contract** — closes the double-credit race | `retire_sortie(...)` with a fallback branch for a group the lifecycle holds no record of | `supply_flight.ts:174` |
| `troop.buildInsert` TTL (2700 s) | **Settles through contract** | `retire_sortie(...)` | `troop.ts:309` |
| `supply.make_land_handler` | Contract adapter | resolves `event.place`, delegates to per-airframe settlement (P3) | `supply.ts` |
| `regen.make_dead_handler` | Contract-aware | skips airframes this system retired; records genuine losses | `regen.ts` |
| `troop.spawnPatrol`, `cas_bai_sead.runArtillery`, ground/static queue callers | **Documented exception** | no aircraft involved; ground/static queue behaviour intentionally unchanged | caller map rows above |

### Lead verification of P4

- `npm run build` → 0; full suite → exit 0 with a new `defect 4 (P4 TARGET)` leg passing.
- Campaign legs at baseline: 423/2831 ticks, 149/153/151 groups, 21 statics, 5 handlers,
  orders 169/179. `git status -- test/golden` empty. No mutation markers in `src` or `test`.
- `npx biome check packages/ee-mission/src` → **18 warnings / 50 infos**, i.e. *two fewer*
  warnings than the 20/50 baseline. No new findings.
- **Negative control run by Lead** (the stalled agent never reported one): forced the
  `supply_flight` backstop to skip `retire_sortie`, rebuilt, and the suite failed with
  `aircraft-lifecycle.lua:1748: the backstop did not settle the airframe`. Restored from a
  pristine copy (`diff` clean), rebuilt, suite green. The P4 leg is load-bearing.

### Still open after P4

- **Backlog card 28** — aircraft losses arrive as CRASH, not DEAD, so nothing ever regenerates.
  Deliberately untouched; needs its own EECH grounding.
- `keysite.SLOT_CAPACITY` vs physical stands — needs an EECH citation.
- The four deferred asymmetries — no EECH citation was found that forces any of them.
