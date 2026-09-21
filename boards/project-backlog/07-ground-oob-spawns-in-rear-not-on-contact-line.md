---
column: backlog
labels: [bug, backend]
priority: high
updatedAt: 2026-09-21T16:40:00.000Z
---
# Ground OOB spawns in the rear, not on the contact line

**Symptom (user report):** ground units always spawn a long distance from the action.

**Root cause:** the port anchors all three ground echelons to the friendly **airbase**. EECH anchors
them to the **road-node boundary between the two sides' territory**.

## What EECH does

`faction.c:1387-1419` selects PRIMARY nodes with an explicit boundary test — a node owned by `side`
that has a direct link to a node owned by the enemy. Its own debug string calls it `(boundary node)`:

```c
for (node2 = 0; node2 < road_nodes[node].number_of_links; node2++)
    if (frontline_forces_data[road_nodes[node].links[node2].node].side == enemy_side)
        frontline_forces_data[node].force_placement_type = FRONTLINE_FORCE_PRIMARY;
```

SECONDARY is then a node linked to a PRIMARY node (`faction.c:1422-1462`), and ARTILLERY a node
linked to a SECONDARY node (`faction.c:1465-1502`) — one and two road-hops back **from the contact
line**. Placement is at the node itself: `pos = &road_node_positions[node]` (`faction.c:1528`), and
the keysite lookup at `faction.c:1548` is only a 1 km parent-entity search, not the spawn point.

Net: at EECH campaign start the two sides' primary groups are adjacent by construction. Contact is
immediate.

## What the port does

| Echelon | Port placement | EECH placement |
|---|---|---|
| PRIMARY | `ground_forces.lua:233` — friendly base centre +/- 800 m | boundary node, adjacent to enemy territory |
| ARTILLERY | `ground_forces.lua:302-304` — 1.5 km **into its own rear** | 2 hops behind the boundary node |
| SECONDARY | `ground_forces.lua:362-364` — 4 km **into its own rear** (`SEC_REAR_OFFSET`) | 1 hop behind the boundary node |

The objective is the nearest enemy base (`ground_forces.lua:437`), and the group drives there at
`COL_SPEED = 8` m/s (`ground_forces.lua:37`).

Measured on the shipped Caucasus theatre (21 airdromes, `apps/web/src/theatres/Caucasus.geojson`):
nearest-neighbour base spacing is **min 4 km / median 37 km / max 89 km**. So a typical group drives
its full base-to-base leg before contact:

| leg | drive time at 8 m/s |
|---|---|
| 40 km | 1.4 h |
| 80 km | 2.8 h |
| 140 km (`front_dist` cap) | 4.9 h |

Worse, the echelons are displaced in the **wrong direction**: secondary and artillery spawn *away*
from the enemy, so they start ~4 km and ~1.5 km further from contact than the primary that is
already at the rear base.

This is not a one-off at OOB. Reinforcement re-spawns at the base too (`ground_forces.lua:626`), so
every replacement group repeats the multi-hour approach for the whole campaign.

The secondary echelon never closes at all: step 2c anchors it `SEC_STANDOFF` (10 km) behind the
**base** (`ground_forces.lua:596-604`), never behind the primary group — so it holds ~47-99 km
behind the fighting instead of EECH's one road-hop.

## Secondary finding — two divergent frontline definitions

`ground_forces.lua` does **not** require `frontline.lua`. It defines its own `frontline_bases()`
(`ground_forces.lua:137-155`) using a 140 km metric band (`config.lua:234 front_dist`). That is
precisely the invented fixed-km threshold that `frontline.lua:20` records as **REFUTED** by spec 06
SECTOR-F16 and replaced with parameter-free Gabriel-graph adjacency. So the air war runs on the
corrected definition while the ground war still runs on the refuted one. `installations.lua:102`
shares the same band.

## Third finding - COL_SPEED is uncited and too slow

`ground_forces.lua:37` sets `COL_SPEED = 8` m/s with no citation. EECH's ground vehicles cruise at
`knots_to_metres_per_second (20.0)` = **10.29 m/s** (`vh_dbase.c:114`, and the dominant value across
the vehicle database - 25 of 38 rows are 20 kt; the outliers are 5/7.5 kt static or towed types and
24/29/32 kt wheeled scouts).

So the port drives its columns ~22% slower than EECH on top of making them travel the full
base-to-base leg. Correcting the placement is the main fix; this compounds it. Per-type velocity from
the vehicle DB would be more faithful still than a single column constant - the group moves at its
slowest member in EECH (`croute.c:316` reads `FLOAT_TYPE_CRUISE_VELOCITY` per member).

## Direction for the fix

Bases are the port's sector/node proxy (the convention `croute.lua` and
`campaign_state.route_difficulty` document, `task.c:876`). The faithful analogue of a boundary node
is therefore the **contact line between Gabriel-adjacent opposing bases** — not the base centre.
Place PRIMARY on the friendly side of that midpoint, SECONDARY one step back from PRIMARY, ARTILLERY
two steps back, all anchored to the primary group rather than the base. Reuse
`frontline.lua`'s adjacency so there is one frontline definition, and derive the echelon offsets from
a cited EECH quantity rather than picking new kilometre figures.

## Checklist

- [ ] Re-read `faction.c:1387-1502` (node selection) and `:1520-1600` (placement) in full
- [ ] Replace `ground_forces.frontline_bases()` with `frontline.lua` Gabriel adjacency; retire the duplicate `front_dist` band
- [ ] Anchor PRIMARY spawn to the friendly side of the contact line, not the base centre
- [ ] Anchor SECONDARY and ARTILLERY to the PRIMARY group, echelon-ward of the enemy — not into the base's rear
- [ ] Fix reinforcement (`ground_forces.lua:626`) to use the same placement, not the base
- [ ] Fix step 2c so secondaries follow the primary line, not the base
- [ ] Derive every offset from a cited EECH quantity; no new hand-picked kilometre values
- [ ] Realign `COL_SPEED` (`ground_forces.lua:37`) to the cited `vh_dbase.c` cruise velocity; prefer per-member slowest-in-group (`croute.c:316`) over one constant
- [ ] `lua-cargo build` 0 warnings + `check` no findings
- [ ] Live-validation soak: confirm first ground contact occurs in minutes, not hours

## Comments

- **claude** (2026-09-21T16:40:00.000Z): Raised from a user report that ground units "always spawn a long distance from the action" — treated as a misalignment report per the PRIME DIRECTIVE rather than a tuning request, and traced to `faction.c:1387-1419`. The EECH rule is unambiguous (its own debug log names the node a "boundary node") and the port's rear-base anchoring is a clear drift from it. Distances computed from the shipped Caucasus geojson, not estimated. Note this interacts with card 04 (the 200 km influence radius) and card 01 (imap radii) — all three are symptoms of the port substituting metric bands for EECH's topological rules, so whoever takes this should read those first.
- **claude** (2026-09-21T16:52:00.000Z): Followed up the one item I had flagged as unaudited in the original write-up. `COL_SPEED` at `ground_forces.lua:37` traces to nothing; EECH's value is `vh_dbase.c:114` (20 kt = 10.29 m/s), uniform across 25 of 38 vehicle rows. Folded into this card rather than raised separately - it is the same defect surface (ground movement) and fixing placement without speed would leave the symptom half-corrected.
