# 0010 — Per-aircraft recovery settlement, site identity, and when credit lands

Date: 2026-09-22. Status: accepted. Context: epic #17 package P3 (sprint 04).

## Context

`supply.make_land_handler` settled an entire group on its **first** member's LAND: released the
sortie slot, credited every unit `getUnits()` returned, and scheduled destruction of the whole
group — while classifying role from the **group-name prefix** and crediting the **nearest
friendly base anywhere on the map**. Live capture showed the failure directly: at t=1954
`Heli-CAS-1-2055-1` crashed on touchdown and at t=1956 its wingman landed, so the old handler
credited a crashed airframe as recovered stock.

## Decision

**1. Settlement authority is the P1 allocation, not the group name.** A sortie record carries
the debited role, side, debit base, expected unit names and a credit budget, and survives
`cs.clear_task()`. `supply.classify_role`'s prefix match survives only as the fallback for
callers P1 has not yet wired; P4 closes that gap.

**2. LAND starts an evaluation, not a credit.** `settle_landing()` resolves the event's own
`place` to a campaign base and returns an explicit outcome (`recovered`, `mission_landing`,
`hostile_site`, `unknown_site`, `confirmed_lost`, `player`, `stale`, …). The positional
"nearest friendly base" proxy is **deleted**, not worked around — justified by 9/9 captured
landings carrying a usable `place` at both airdromes and FARPs.

**3. Credit is coupled to retirement, and therefore lands ~30 s later than before.** Nothing is
credited while the airframe is still in the world; the ledger moves only when the aircraft is
actually retired, after re-checking generation, sortie identity, member state, live unit
identity and player control. The delay is the pre-existing
`LANDED_GROUP_CLEANUP_DELAY_SECONDS`; no new constant. **Accepted deliberately** — the
alternative (credit at touchdown) is exactly the duplicate-airframe hazard the epic's
invariant 4 forbids, since the physical aircraft still exists and still holds its stand.

**4. The keysite launch slot is released when every member is resolved, not on the first
landing.** Consequence: a sortie with a permanently unaccounted member holds its slot.
Accepted because the opposite error — releasing a slot while aircraft are still airborne — is
the bug being fixed. `unsettled_sorties()` makes the exposure visible, and P4 wiring the four
timer paths through `resolve_sortie()` bounds it.

**5. Losses arrive as CRASH, and that is observed, not assumed.** See backlog card 28 — this
package did not change regeneration behaviour, but it does guarantee that a **cleanup-generated**
death is never counted as a fresh combat loss or a regeneration request.

EECH grounding (verified by Lead in `E:\eech_source_code`): `force.c:211-243` /
`249-271` / `278-300` each move **one entity** (`current++/reserve--`, `current--` + loss stat
at `:258`, `reserve++` at `:297`) — the per-airframe shape, not per-group.
`hc_dstry.c:343-346` and `fw_dstry.c:332-335` gate on `INT_TYPE_ALIVE`, which is EECH itself
declining to charge a loss for removing something no longer a live fielded asset; that is the
citation behind the cleanup-death guard. No numeric constant was introduced.

## Consequences

- Four timer paths (`reaction.expireCap`, the BDA loiter, `supply_flight.scheduleBackstop`, the
  troop TTL) still settle outside the contract. `resolve_sortie(groupName, reason)` exists and
  is tested as their entry point. Until P4 wires them there is a **narrow double-credit race**:
  a supply flight not credited at delivery could be force-recycled by its backstop *and*
  credited if it later lands home. Recorded, bounded, and owned by P4.
- `S._recycled` is keyed by unit name in the settlement path while `reaction.recycleOnce` still
  keys it by group name. No collision is possible (unit names are `<group>-<n>`), but the key
  spaces should be split in P4.
