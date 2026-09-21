---
column: review
labels: [bug, backend]
priority: high
agent: claude
live: false
updatedAt: 2026-09-21T17:20:00.000Z
---
# Sorties start from the ramp, not the runway

> **Paths re-pointed 2026-09-21.** The Lua baseline was deleted; module paths below now name
> their `packages/ee-mission/src/*.ts` counterparts. **Line numbers were taken against the Lua
> tree** and will not map exactly — locate by symbol, or read the original via
> `git show <pre-deletion-commit>:Scripts/ee-dcs/<module>.lua`. EECH C-source citations
> (`E:\eech_source_code`) are unaffected.


**Symptom (user report):** sorties start runway-hot; they should start from the ramp.

**Root cause:** every AI spawner paired `type="TakeOff"` with `action="From Parking Area"`. In DCS
the **`type` field is authoritative** - `TakeOff` means *runway* - so aircraft spawned on the runway
despite the parking `action` and despite every surrounding comment claiming a parking start.

The repo already contained the correct pairings, which is why **player** slots appeared on the ramp
while AI sorties did not:

- `apps/web/src/lib/slots.ts:170-174` - `type: 'TakeOffParkingHot'` + `action: 'From Parking Area Hot'`
- `packages/ee-mission/src/farp_parking.ts:56-57` - `type = "TakeOffParking"` + `action = "From Parking Area"`

Valid DCS pairings:

| Start | `type` | `action` |
|---|---|---|
| Runway | `TakeOff` | `From Runway` |
| Ramp cold | `TakeOffParking` | `From Parking Area` |
| Ramp hot | `TakeOffParkingHot` | `From Parking Area Hot` |
| Ground cold (FARP) | `TakeOffGround` | `From Ground Area` |
| Ground hot (FARP) | `TakeOffGroundHot` | `From Ground Area Hot` |

## Decision

User chose **hot ramp** (`TakeOffParkingHot`). Cold start was rejected because AI startup (~5-8 min
jets, ~3-5 min helis) would frequently make reaction-chain sorties - intercepts, SEAD response, BDA -
arrive after the event they were reacting to, against a 7.5 min keysite-strike and 2 min
troop-insertion cadence.

## Work done

26 sites converted to `type="TakeOffParkingHot"` + `action="From Parking Area Hot"`:

- **Lua (13):** `attack_waves.ts` x2, `cas_bai_sead.ts` x3, `heli_war.ts` x2, `reaction.ts` x2,
  `recon.ts`, `regen.ts`, `supply_flight.ts`, `troop.ts`
- **TypeScript mirror (13):** the matching sites in `packages/ee-mission/src/*.ts`

`TakeOffGroundHot` sites (padless FARP / bare-coordinate starts) were left unchanged - correct as-is.
Stale comments describing "a real TakeOff waypoint" / "TakeOff-from-parking" updated in
`attack_waves.ts`, `heli_war.ts`, `troop.ts`. The matched-pair rule and the DCS trap are recorded
in `CLAUDE.md` under the superseded-constraint bullet so it is not reintroduced.

Consistent with the existing CLAUDE.md constraint: ramp starts **are** ground spawns, so this moves
further toward that rule, not back toward in-air spawns.

## Gates

- [x] lua-syntax - `luac5.1 -p Scripts/ee-dcs/*.lua` clean across all 34 modules (claude, 2026-09-21T17:20:00Z)

## Checklist

- [x] Convert all 13 Lua sites
- [x] Convert all 13 TypeScript mirror sites
- [x] Leave `TakeOffGroundHot` FARP starts unchanged
- [x] Update stale comments
- [x] Record the matched-pair rule in CLAUDE.md
- [ ] `lua-cargo build` 0 warnings + `check` no findings - **BLOCKED**, DCS Studio MCP refusing on 127.0.0.1:25570
- [ ] Live check: AI flights appear on parking spots, engines running, and taxi without blocking the runway
- [ ] Watch for parking-capacity contention at busy fields during reaction bursts (ramp starts need a free spot; runway starts did not)

## Comments

- **claude** (2026-09-21T17:20:00.000Z): Implemented before the "RepoDoc cards only" instruction landed; card written afterwards so the board reflects the working tree. Changes are uncommitted in `E:\ee-dcs`. The fix itself is a one-token change per site, but worth reviewing the last checklist item: runway starts never needed a free parking spot, so a busy field under a reaction burst could now fail to spawn where it previously succeeded. Not yet observed - flagging as a risk, not a known defect.
