---
column: review
labels: [backend, frontend]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:28:00.000Z
---
# Use industrial areas and warehouses as spawn sites

Treat each OSM `landuse=industrial` polygon as a factory candidate unless a more-specific tag applies, including unnamed areas. Treat warehouse-tagged features as depot candidates. Keep one spawn type and one dot per source footprint. Retain every in-theatre industrial polygon without geographic caps. See [Decision 02](../../decisions/02-industrial-candidate-options.md) and [Decision 04](../../decisions/04-uncapped-osm-candidates.md).

## Checklist

- [x] Export industrial polygons and their on-footprint centre points
- [x] Keep one spawn enum and one dot per candidate
- [x] Retain every in-theatre industrial polygon and rebuild Caucasus
- [x] Test classification, UI compilation, export and generation

## Comments

- **codex** (2026-09-21T21:08:20.000Z): `apps/web/src/lib/osm-policy.mjs:30` currently requires a name and returns one type, while `apps/web/scripts/export-osm.mjs:18` does not explicitly extract `landuse=industrial`. `apps/web/src/lib/balance.ts:210` selects per type, so a dual-use site needs source deduplication. The cached regional PBF is available and Docker can be accessed with elevation for a complete refresh.
- **codex** (2026-09-21T21:22:00.000Z): User clarified that each source must have one kind: industrial land maps to factory and warehouse tags map to depot. The refreshed Caucasus export includes 80 factory candidates across 40 broad H3 regions and 67 depots across 36, each capped at two per region. Exporter uses an inside-footprint centre, with an on-footprint fallback. The one-source-one-dot assertion and web checks pass; ready for review.
- **codex** (2026-09-21T21:28:00.000Z): User explicitly removed all regional caps and proximity deduplication. The current export has 43,843 candidates; the local coverage test verifies all 32,504 in-theatre `landuse=industrial` polygons are represented. Map dots are viewport-culled and canvas-rendered.
- **codex** (2026-09-21T21:48:00.000Z): The later active-area crop is a spatial boundary, not a density quota. All 8,227 eligible industrial polygons inside the playable rectangle remain in the compressed export. Site-footprint precedence removes only component dots, never a distinct industrial land polygon.
