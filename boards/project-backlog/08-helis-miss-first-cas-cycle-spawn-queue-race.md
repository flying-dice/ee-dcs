---
column: backlog
labels: [bug, backend]
priority: high
updatedAt: 2026-09-21T17:10:00.000Z
---
# Helicopters miss the first CAS cycle - spawn-queue race at boot

> **Paths re-pointed 2026-09-21.** The Lua baseline was deleted; port modules below name their
> `packages/ee-mission/src/*.ts` counterparts. **Line numbers were taken against the Lua tree**
> and will not map exactly — locate by symbol, or read the original with
> `git show <pre-deletion-commit>:Scripts/ee-dcs/<module>.lua`. EECH C-source citations are
> unaffected.


**Symptom (user report):** the air war opens with jets flying recon and strikes; helicopters take a
long time to appear. In EECH, helicopters are in the campaign immediately.

**Root cause:** the port materialises the world **asynchronously** through `spawn_queue`, but the
schedulers use EECH's `start_time` offsets, which assume the fully-instantiated world EECH has at
`start_high_level_ai()`. CAS - the port's rotary generator - fires before its targets exist, finds
nothing, and does not retry for a full period.

## Why jets fly and helis do not

CAS and BAI **are** the rotary fight here: `create_air_strike_task` routes both to
`heli_war.build_attack_heli` (`cas_bai_sead.ts:412-417`); only SEAD stays fixed-wing. So rotary
sorties depend entirely on CAS/BAI finding targets.

The two generators draw targets from different places:

| Generator | Offset | Target source | Available at T+5s? |
|---|---|---|---|
| `cas` (ROTARY) | **5 s** | `coalition.getGroups(enemy)` - **live DCS ground groups** (`cas_bai_sead.ts:495`) | **No** - still in the spawn queue |
| `keysite_strike` (JET) | 15 s | `S.base_owner` / keysite map - **plain state, populated synchronously in init** | Yes |

`spawn_queue` drains `DRAIN_PER_TICK = 4` every `DRAIN_INTERVAL = 1.0` s (`spawn_queue.ts:23-26`)
against an init burst its own header puts at ~150-200 groups. Boot enqueues in this order
(`game_loop.ts:172-208`): FARP statics -> **ground OOB** -> installations -> AD garrisons.

Critically, `init_oob` loops `{BLUE, RED}` in order (`ground_forces.ts:401`), so **every BLUE ground
group is enqueued before the first RED one**. At T+5 s roughly 20 items have drained - the FARP
statics and the leading BLUE groups. BLUE's CAS is looking for **RED** ground groups, which do not
exist yet.

So `run_cas` hits its guard at `cas_bai_sead.ts:561-565`, logs `CAS: no ground targets found`, and
returns. The next BLUE CAS is **15 minutes later** (`campaign_mode.ts` cas period 15 min,
`highlevl.c:246`). Meanwhile `keysite_strike` at T+15 s has keysites available immediately, launches
jets, and its recon-first fork (`highlevl.c:1179-1205`) produces the recon sorties the user sees.

Net: **jets at T+15 s, first attack helicopters at T+15 min or later.** In EECH,
`initialise_order_of_battle` completes synchronously before `start_high_level_ai()`, so
`create_cas_tasks` at `start_time 0.0` (`highlevl.c:246`) sees a fully populated world and
helicopters are in the fight from the first tick - exactly what the user remembers.

This is a **port-infrastructure race, not an EECH divergence**: the cadences are correct (audited
2026-09-21), but they are being applied to a world that is not finished loading.

## Compounding factor

Card 07 (ground OOB spawns in the rear) means that even once the groups exist, they are 1-3 hours of
driving from contact. CAS rates only `frontline`-echelon targets (`cas_bai_sead.ts:574-577`), so
until the columns close, rotary CAS has little to rate even on later cycles. **Fix 07 and 08
together** - either alone leaves the rotary war thin at campaign open.

## Candidate fixes (pick after measuring)

1. **Gate the schedulers on queue drain** - do not start the generator timers until `spawn_queue` is
   empty, then apply the EECH offsets from that instant. Most faithful: reproduces EECH's
   "OOB complete, then start the AI" ordering exactly. Preferred unless drain is slow.
2. **Retry on empty** - if a generator finds no targets, re-arm at a short retry interval instead of
   waiting a full period. Cheap, but invents a retry cadence EECH does not have.
3. **Raise `DRAIN_PER_TICK`** - the 4/tick throttle exists for a crash that `spawn_queue.ts:22-24`
   says was root-caused to `launch lights=0`, not spawn volume. If that holds, the throttle may be
   over-conservative now. Reduces the race window but does not close it.

## Checklist

- [ ] Instrument boot: log queue depth + drain-complete timestamp, and the live ground-group count at each generator's first fire
- [ ] Confirm the measured first-CAS-success time against the ~15 min predicted here
- [ ] Choose a fix (prefer 1 - it reproduces EECH's ordering rather than inventing a retry)
- [ ] Verify BLUE and RED both launch rotary CAS on their first cycle
- [ ] Re-check `troop_insertion` (60 s) and `hc_transfer` (120 s) for the same race - they also need live targets
- [ ] `lua-cargo build` 0 warnings + `check` no findings
- [ ] Live-validation soak: first attack-helicopter sortie within the first CAS cycle

## Comments

- **claude** (2026-09-21T17:10:00.000Z): Raised from a user report that helicopters take far too long to enter the air war versus EECH. Traced end to end: `cas_bai_sead.ts:412-417` (CAS/BAI are rotary), `cas_bai_sead.ts:495` (targets are live DCS groups), `spawn_queue.ts:23-26` (4 spawns/s), `game_loop.ts:172-208` (enqueue order), `ground_forces.ts:401` (BLUE enqueued before RED), `cas_bai_sead.ts:561-565` (the empty-target early return). The scheduler cadences themselves are correct and were verified against `highlevl.c:246-268` in the 2026-09-21 audit - this is an ordering defect in port infrastructure, which is why it did not show up in a constants-focused fidelity pass. Not yet measured in a live mission; the ~15 min figure is derived, and the first checklist item is to confirm it.
- **codex** (2026-09-21T22:25:00.000Z): Live mission evidence narrows this card: CAS helicopter groups were assigned and drained successfully at 22:04:07 UTC (`dcs.log` lines 1837-1845, 1867-1871), so the predicted spawn-queue race does not by itself explain the player's current report of no helicopters visible on F10. Post-spawn visibility/departure is tracked in [GitHub #3](https://github.com/flying-dice/ee-dcs/issues/3). Keep this card's first-cycle timing hypothesis separate until measured directly.
