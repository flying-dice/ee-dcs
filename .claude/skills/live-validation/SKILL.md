---
name: live-validation
description: Use when running end-to-end validation of the EECH campaign port in a live mission (ideally an MP dedicated server) — the current P0. Covers prerequisites (empty Caucasus mission, DCS Studio up), the inject command, a per-system observation checklist with expected env.info lines and timings, what "healthy" looks like, common failure signatures, multi-hour soak guidance, MP player-slot checks, and what cannot yet be validated.
---

# Live validation runbook

End-to-end validation of the campaign in a live mission. This is goal 03's P0: the port builds
clean but must be proven to actually *run* over a multi-hour soak. Ideally on an MP dedicated
server.

## Prerequisites

- **DCS is running an EMPTY Caucasus mission** — nothing placed in the mission editor. The port
  discovers airbases from the map and spawns the entire OOB via `coalition.addGroup` at inject time.
  Wrong theatre or a mission with pre-placed units invalidates the run.
- **DCS Studio desktop app is up** so the MCP tools (`dcs_eval`, build, check, DB, log) exist. If
  they are absent, tell the user to start DCS Studio and reconnect the session (see `dev-loop`).
- The mission must actually be **running** (sim_running = true), not sitting at the main menu. At
  the main menu you can query the DB and build, but nothing schedules.

## Inject

Build + check clean first (see `dev-loop`), then via the `dcs_eval` MCP tool:

```
net.dostring_in('server', 'dofile("C:/Users/jonat/DCSStudio/my-test-mod/dist/dynamic-mission-test.lua")')
```

Re-injection mid-session is safe (the `_DMT_GEN` generation guard self-cancels old timers). Then
watch `Saved Games/DCS/Logs/dcs.log` (or the log-reading MCP tool if present) for `env.info` output.

## Observation checklist (per-system, with expected timing)

Timings below are from the scheduler table (ANALYSIS §1): **period** is the cadence, **offset** is
the first fire after inject. BLUE fires earlier than RED by design. A tick firing does not
guarantee a spawn — it spawns only when a valid target and reserve exist, so absence of a spawn line
is not necessarily a fault; a script **error** always is.

- **T+0 (synchronous init):** init sequence lines in order — base state, strength recalc, supply
  init (per-side reserve pools seeded), imap init, FOW init, frontline build, regen init, keysite
  repair init, ground OOB (standing frontline companies spawn), installations init (depot/fuel/radar
  statics behind bases). Expect the standing ground groups and static installations to appear on the
  map immediately.
- **FOW decay + recon scan** — period 30s, offset 8s. First tick by ~8s, then every 30s.
- **imap (4 layers)** — period 120s each, offsets 20/40/60/80s.
- **keysite repair + efficiency**, **regen dequeue** — period 60s.
- **frontline rebuild** — period 120s.
- **admin capture-poll + win check** — period 60s (offset 90s). **admin status/phase log** — period
  120s: your periodic "phase / strength / reserves" heartbeat.
- **ground keysite strike** — period 450s (7.5min), BLUE offset 15s / RED 240s. Expect BLUE ground
  strikes within the first ~7.5min.
- **heli anti-armour** — period 480s (~8min), offsets 60/105s. Attack-heli sections vs the enemy
  frontline armour — this is the heart of EECH, watch for it.
- **heli hunter-killer** — period 600s, offsets 120/165s.
- **CAS** — period 900s (15min). **artillery** — period 900s. **BAI** — period 1200s. **SEAD** —
  period 720s.
- **troop insertion** — period 120s (checks every 2min; spawns only when a capture opportunity
  exists). **troop patrol** — period 300s.
- **ground advance/retreat** — period 720s (12min), BLUE offset 12s. Ground groups retarget toward
  the nearest enemy base / retreat when weakened.
- **OCA strike** — period 1800s (30min), BLUE offset 390s. **OCA sweep** — period 1800s.
- **supply reserve log** — period 600s (10min): per-side reserve pool levels.
- **FW / HC transfer** — period 900 / 450s. **F-10 map overlay** — period 30s (ownership, task
  arrows, columns, frontline redraw).
- **reaction (event-driven, not scheduled):** on a strike's **birth** the defender scrambles
  CAP/BARCAP at the real objective; on **land** (RTB = success) the completion follow-on chain fires
  (recon→SEAD/BAI, BDA, follow-on strikes). Watch for these around strike lifecycles, not on a clock.

## What "healthy" looks like

- **Reserves deplete and recycle:** the 10-min supply log shows per-side pools drawing down as
  sorties launch and ticking back up as flights RTB (S_EVENT_LAND recycles survivors). A pool that
  only ever falls and never recovers is a **refund leak** (see `dev-loop`).
- **Strength moves:** the strength census shifts as hardware is lost/regenerated; it is not pinned
  at 50/50 (that value only appears when no units are fielded — should never happen live).
- **Phase advances** over time; phase/status heartbeat prints every 2min.
- **No script errors** anywhere in dcs.log. That is the top-line pass condition.
- Ground frontline present and moving; strikes/recon/reaction/heli-war all producing spawn lines
  over the first ~30-40min as their cadences come round.

## Common failure signatures

- **`nil` position errors** (e.g. indexing `base_pos[...]` nil, `wp_xy` on nil) — usually a target
  base that was captured/destroyed mid-flight, or an installation removed at ≤0.1 health. Guard the
  lookup.
- **`addGroup` returned nil → refund line** — a spawn failed to place; confirm the matching
  `recycle_side` refund fired (grep the log around it). A failed spawn with **no** refund line is a
  pool leak.
- **Missing / invalid type name** — `coalition.addGroup` silently places nothing, or a static
  degrades to an abstract point. Re-verify the type name / CLSID against the live DB (never guess).
- **Double-registered schedulers** (every tick appearing twice) — the `_G.game_loop` double-start
  footgun (ANALYSIS §7); only occurs if `game_loop` is loaded in a way that leaks the global.
- **Unbounded F-10 mark growth** — task arrows are never removed (`remove_task_arrow` has zero
  callers); on long sessions mark IDs accumulate. Watch mark count on soak.

## Soak test guidance (multi-hour)

- Let the campaign run for **hours**, not minutes — the interesting economy behaviour (reserve
  exhaustion, regen pressure, frontline movement, win-criteria approach) emerges slowly.
- **Watch mark growth:** F-10 marks/arrows accumulate (known slow leak, ANALYSIS §6d). Note whether
  it becomes a problem over the soak.
- **Watch per-tick cost:** the O(bases × groups) enumeration loops (transfer idle scan, FOW triple
  loop, imap) rebuild every period; as unit counts grow, tick cost grows. Flag if it degrades.
- Sample the reserve/strength/phase heartbeat periodically to confirm the economy is still live and
  not stalled or leaked to zero.

## MP-specific checks (once player slots exist)

Player slots **cannot** be created by `coalition.addGroup` — they must be baked into a `.miz` as
Client-skill groups or provided via DCS 2.9 dynamic spawn (GOAL.md P0, ANALYSIS §6f). Until slots
exist, the player-facing paths **cannot be validated at all** — be honest about that in the journal.

When slots do exist, verify:

- **Join mid-campaign** into an ongoing war; **fly** a sortie (kills/losses/recon should feed the
  economy); **disconnect**; **rejoin** later — campaign state unaffected across the cycle.
- **No player unit is ever destroyed, recycled, regenerated, or misclassified** by supply / regen /
  reaction. Confirm: the supply land handler and reaction land handler skip players
  (`getPlayerName` guard) — but the **regen dead handler is NOT player-guarded** today (relies on
  name-prefix classification only); a client group accidentally named like an AI group would be
  regenerated as AI. Test a player death and confirm no regen enqueue.
- Human units currently **count in the strength census** (`count_current_hardware`) — verify whether
  a coalition-stacked server distorts the AI economy (ANALYSIS §6b); this is an open P1 decision.

## Cannot yet be validated

Per GOAL.md P0/P1, these have no live surface until player slots are provisioned: join/leave
lifecycle, situational-brief-on-join, player-safe economy end to end, and persistence across a
server restart (state is in-memory only — a `DCS_server.exe` restart resets to OOB). Record these as
blocked-pending-slots, not as passed.
