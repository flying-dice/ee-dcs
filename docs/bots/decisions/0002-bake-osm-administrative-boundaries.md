# ADR 0002 — Bake OSM administrative boundaries with theatre data

## Context

Scenario generation needs district boundaries without making runtime Overpass requests. The local planet PBF and cached theatre extract already feed the static OSM companion file loaded alongside each DCS theatre export. OSM administrative levels vary by country, so a global `ADM2` label is less precise than retaining the source level.

## Decision

The OSM exporter selects administrative relations at `admin_level=6` as the Caucasus district-level proxy. It converts Osmium relation-area identifiers back to stable `relation/<id>` source IDs, simplifies the polygons with Turf, retains identifying tags and writes them as `kind: "admin-boundary"` features in `apps/web/src/osm/<Theatre>.geojson`.

The browser loader exposes these polygons as typed `AdminBoundary` records. The stored `adminLevel` and raw tags remain authoritative so later theatres can use a different level without changing the asset schema.

The map renders the boundaries as the scenario's territory layer. Clicking a boundary opens a modal where the user explicitly chooses BLU or RED ownership and a Rear or Close role, or clears the assignment. The app does not infer operational roles from distance or topology.

Assignments govern generation. Airbases inherit the side of their containing territory, and a side's main airbase must be inside its territory. FARPs and radar are generated only in Close territory; factories, refineries, ports, power and command are generated only in Rear territory. Airbases may be selected from either role.

## Consequences

- Theatre selection loads DCS geometry, OSM keysite/objective points and administrative boundaries from two matching static files.
- Deployed browsers make no boundary data request.
- Adding a theatre may require choosing its country-appropriate OSM level rather than assuming level 6 always means ADM2.
- Simplified boundaries are suitable for scenario planning and display, not legal or cadastral use.
- Territory assignments reset with the distribution and are the authoritative ownership and placement constraint for scenario keysites.
