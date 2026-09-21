---
column: backlog
labels: [feature, backend]
priority: high
updatedAt: 2026-09-21T18:05:00.000Z
---
# Build a real road graph from OSM and close the "structural limit" proxies

> **Paths re-pointed 2026-09-21.** The Lua baseline was deleted; port modules below name their
> `packages/ee-mission/src/*.ts` counterparts. **Line numbers were taken against the Lua tree**
> and will not map exactly — locate by symbol, or read the original with
> `git show <pre-deletion-commit>:Scripts/ee-dcs/<module>.lua`. EECH C-source citations are
> unaffected.


The port repeatedly declares "DCS exposes no road-node adjacency graph" a **structural limit that
cannot be closed**, and substitutes metric/base-centric proxies for EECH's topology. That premise
was true when the port was written. With OSM available it no longer is - and several proxies can be
replaced with direct ports rather than approximations.

## What EECH actually needs

`ai_route.h:115-152` - the entire ground-movement substrate is three small structures:

```c
struct NODE_DATA { node, safe_radius, number_of_links, visited,
                   side_occupying, side_aware, side_exploring; link_data *links; };
struct LINK_DATA { int cost; node, breaks; };
struct NODE_LINK_DATA { source, destination, path_type, number_of_links; vec3d *link_positions; };
```

So: **node positions + weighted adjacency + a polyline per link**. Every one of those is directly
derivable from OSM `highway=*` ways (junctions -> nodes, segments -> links, segment length -> cost,
highway class -> `path_type`, way geometry -> `link_positions`).

**`safe_radius` is not a blocker.** `initialise_road_safe_radius()` (`ai_route.c:1170-1232`), which
derives it from a terrain probe, is **commented out in shipped EECH**. The live value is the hardcoded
`new_node->safe_radius = 28` at `ai_route.c:414`. So the port's existing `7 +/- 2` group size
(`ground_forces.ts:70-72`, from `28/4 +/- 2`) is already correct and needs no OSM input.

## Two ways to get the graph - DCS-derived is now preferred

**Revised 2026-09-21 after user challenge: can the DCS road APIs do this instead?** Largely yes, and
it avoids this card's biggest risk. Assessment:

DCS gives three relevant primitives - `land.findPathOnRoads(type, x1,y1,x2,y2)` (polyline route),
`land.getClosestPointOnRoads(type, x, y)` (snap), and `land.getSurfaceType(p) == ROAD` (already in
`dcs.d.ts:344`). Between them they cover **movement, cost and snapping** better than OSM can, because
they return DCS's *own* mesh - no alignment risk, and a route they return is drivable by definition.

What they cannot do is **enumerate or expose adjacency**. There is no "list all road junctions" call,
and `findPathOnRoads` is a point-to-point query that says nothing about a node's neighbours. EECH's
core loops need exactly that:

```c
for (node = 0; node < total_number_of_road_nodes; node++)      // faction.c:1387, :1422, :1465
    for (node2 = 0; node2 < road_nodes[node].number_of_links; node2++)
        if (...links[node2].node is enemy-owned) -> mark PRIMARY
```

You cannot run boundary marking, echelon marking, or one-node-per-tick advance without a node set and
its links.

**But the graph can be DERIVED from DCS rather than imported from OSM.** Sample seed points (airbases,
OSM `place=*` towns, a coarse grid), call `findPathOnRoads` between pairs, union the returned
polylines, detect shared vertices as junctions, and bake the result. The output is a graph guaranteed
to match DCS's mesh.

**The harness for this already exists.** `tools/dcs-export/theatre-dump.lua` is exactly this pattern:
a DCS hook running in the GUI env (which has `io`/`lfs`), pulling mission-env data via
`net.dostring_in`, writing a geojson into the repo - and it explicitly notes it needs no
`MissionScripting.lua` changes. A road-graph bake is the same tool with a different query, and it
runs **offline**, so per-call cost of `findPathOnRoads` stops being a runtime concern.

So the recommended approach is now:

| Source | Use for |
|---|---|
| **DCS `findPathOnRoads`, baked offline via a `theatre-dump`-style hook** | node/link graph, link geometry, cost - the primary source |
| OSM | fallback if junction detection proves unreliable, plus enrichment DCS has no notion of (road class -> `path_type`, and `place=*` population areas for `faction.c:1530`) |

This removes the "do OSM roads align with the DCS mesh?" unknown entirely. OSM drops from
*prerequisite* to *optional enrichment*.

### Data situation (OSM, if still wanted)

- `apps/web/.osm-work/Caucasus/region.osm.pbf` - 1.25 GB raw Caucasus OSM, contains the road network.
- `apps/web/src/osm/Caucasus.geojson` - the 50 MB compiled asset - has **no roads**: 257,792 features,
  all Point/MultiPolygon, zero `highway` tags.
- Cause: `apps/web/scripts/export-osm.mjs:19-32` filters POIs only; there is no `highway` rule. Roads
  are excluded by the export, not absent upstream - confirmed with the user.

## What this would let us port faithfully

| Currently a proxy | Becomes |
|---|---|
| **Card 07** - ground OOB at base centres; boundary approximated by base midpoints | Direct port of `faction.c:1387-1419`: PRIMARY = node linked to an enemy-owned node. SECONDARY/ARTILLERY = 1 and 2 links back (`faction.c:1422-1502`). No invented offsets at all. |
| Continuous base-to-base driving (`ground_forces.ts:23-27`) | EECH's real discretisation: advance **one group one node per tick** toward the warmest reachable node (`highlevl.c:250`, create_advance_and_retreat_tasks). Fixes pacing as well as placement. |
| `SEC_STANDOFF` / `SEC_REAR_OFFSET` / `ARTY_STANDOFF` metric guesses | Deleted - echelon depth becomes link count, as in EECH. |
| `croute` sector_side = nearest-base owner (`croute.ts:25-30`, proxying `croute.c:1534-1536`) | `side_occupying` per node - real territorial state. |
| Air-only resupply (`supply_flight.ts:26-31`) | EECH's land-convoy branch of `create_supply_task` becomes reproducible. |
| Base-ownership as the only territory model | Node `side_occupying` gives genuine territorial control - the front can move *between* bases instead of only at them. |

It may also bear on the sector-grid limit that `imap.ts:11-13` and `frontline.ts:15-22` both cite:
OSM admin boundaries (already exported, 832 MultiPolygons) plus road-node occupancy could support a
real sector model rather than the base-proxy. **Treat that as a separate follow-up** - do not scope
it into this card.

Note the compiled OSM already carries `place=city,town,village,hamlet` - EECH's
`check_point_inside_population_area()` gate (`faction.c:1530`) has a real data source too, which is a
cheap independent win.

## Scope warning

This is the largest item on the board and it touches the campaign's movement substrate. It should be
staged, not attempted in one pass, and it supersedes the *approach* in card 07 (the symptom and the
EECH citations there remain correct - only the "bases are the nodes" workaround is replaced).
Sequencing suggestion: data export -> graph build + validation -> placement (card 07) -> node-step
advance -> everything else.

## Open questions

- Can junctions be detected reliably from unioned `findPathOnRoads` polylines, or do returned paths
  share vertices too inconsistently? This is now the main technical risk, and it replaces the old
  OSM-alignment question.
- Graph size: how many junction nodes does Caucasus yield after filtering to major classes, and is
  per-tick traversal affordable in the mission-scripting environment? EECH's node index is 14 bits
  (max 16,383 nodes) - a useful sanity bound for how coarse the graph should be.
- Does the graph get precomputed at export time (shipped as data, like the theatre geojson) or built
  at mission start? Precomputed is almost certainly right - it keeps mission-start cost near zero.

## Checklist

- [ ] Prototype a `theatre-dump`-style hook that bakes a road graph from `land.findPathOnRoads`
- [ ] Solve junction detection from unioned path polylines; validate the graph is connected
- [ ] Validate node count against the 14-bit EECH bound; measure in-mission lookup cost
- [ ] Only if DCS-derived junctions prove unreliable: add a `highway` filter to `export-osm.mjs` as fallback
- [ ] Consider OSM enrichment regardless: road class -> `path_type`
- [ ] Port `faction.c:1387-1502` boundary/echelon placement onto the graph (closes card 07 faithfully)
- [ ] Port one-node-per-tick advance/retreat (`highlevl.c:250`)
- [ ] Replace `croute` sector_side proxy with node `side_occupying`
- [ ] Delete `SEC_STANDOFF` / `SEC_REAR_OFFSET` / `ARTY_STANDOFF` metric constants
- [ ] Re-evaluate the land-convoy branch for `supply_flight`
- [ ] Gate placement on OSM `place=*` population areas (`faction.c:1530`)
- [ ] Update CLAUDE.md: the road-graph "structural limit" is no longer accurate

## Comments

- **claude** (2026-09-21T18:05:00.000Z): Raised at user request after they pointed out the port predates the OSM data. Verified the premise both ways: the road-graph limit is cited in `ground_forces.ts:23`, `ground_forces.ts:101`, `ground_forces.ts:109` and `supply_flight.ts:29` as uncloseable, and the raw PBF does hold the roads while the compiled export drops them. The find that most improves the cost/benefit here is `ai_route.c:414` - `safe_radius` is a hardcoded 28 in shipped EECH and the terrain-derived version at `ai_route.c:1170` is commented out, so the OSM graph only has to supply positions and adjacency, not terrain-derived radii. That makes this a tractable data problem rather than a terrain-analysis one. Have not prototyped the extraction or measured graph size - the open questions above are genuine unknowns, not rhetorical.
- **claude** (2026-09-21T18:25:00.000Z): Revised after the user asked whether the DCS road APIs could achieve this without OSM. They largely can, and I have reworked the approach above rather than defending the original framing. The hard limit is real - DCS exposes no enumeration or adjacency, which EECH's `for each node, for each link` loops require - but the graph can be *derived* from DCS and baked offline, and `tools/dcs-export/theatre-dump.lua` is already the exact harness pattern for doing it. That is strictly better than importing OSM roads because it eliminates the mesh-alignment risk. OSM is demoted to optional enrichment (road class, population areas). Title still says OSM; leaving it so the card stays findable, but the approach is now DCS-first.
