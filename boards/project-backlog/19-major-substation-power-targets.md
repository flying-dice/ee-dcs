---
column: review
labels: [backend, bug]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:37:00.000Z
---
# Include major substations as power targets

The Zugdidi 220 kV transformer station should be a power spawn target. Keep small distribution substations and individual transformers out. See [Decision 05](../../decisions/05-major-substation-power-targets.md).

## Checklist

- [x] Inspect the Zugdidi source feature and voltage tags
- [x] Add a major-substation policy and OSM extraction
- [x] Rebuild the Caucasus candidate asset
- [x] Verify target inclusion, small-site exclusions and app checks

## Comments

- **codex** (2026-09-21T21:31:00.000Z): `apps/web/src/lib/osm-policy.mjs:43` currently admits only large generating plants as power targets, and `apps/web/scripts/export-osm.mjs:32` filters only `power=plant`; thus a 220 kV substation cannot enter the candidate pipeline.
- **codex** (2026-09-21T21:37:00.000Z): The local OSM feature `a1340413738` is a named 220 kV transmission-substation polygon. `apps/web/src/lib/osm-policy.mjs:24` now admits substation areas with a documented voltage of at least 220 kV while excluding several component roles; `apps/web/scripts/export-osm.mjs:32` extracts the tags. Rebuilt `apps/web/src/osm/Caucasus.geojson:1` contains Zugdidi as power and 367 qualifying substations. `apps/web/scripts/check-osm-candidates.mjs:72` tests the exact feature; OSM tests, type-check, production build and mission-roster test pass. Ready for human review.
- **codex** (2026-09-21T21:48:00.000Z): Zugdidi remains a power candidate in the active-area gzip export; the map-area crop leaves 155 power candidates overall. The exact feature ID is still asserted by the OSM test.
