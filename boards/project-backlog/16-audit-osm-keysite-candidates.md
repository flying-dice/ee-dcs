---
column: review
labels: [backend, perf]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:03:18.000Z
---
# Audit strategic OSM keysite candidates

Keep enough geographically distributed, high-confidence locations for the campaign without drawing every small industrial component as a potential keysite. See [Decision 01](../../decisions/01-strategic-osm-keysite-selection.md).

## Checklist

- [x] Audit current class counts and sample false positives
- [x] Align exporter and browser on one classification policy
- [x] Apply conservative class rules and geographic thinning
- [x] Rebuild Caucasus and test representative inclusions/exclusions
- [x] Update documentation and verify the web app

## Comments

- **codex** (2026-09-21T20:55:57.000Z): `apps/web/src/osm/Caucasus.geojson:1` has 318 factories, 33 refineries, 23 ports, 36 power sites, one weather radar, four command sites and six depots. `apps/web/scripts/export-osm.mjs:50` classifies generic `man_made=works` as factory and all `industrial=oil` as refinery; `apps/web/src/lib/classify.ts:86` mirrors those rules. This admits compressor/rail works, oil tanks and pump stations. The campaign defaults to just two factories and one other strategic type per side at `apps/web/src/lib/balance.ts:5`.
- **codex** (2026-09-21T21:01:00.000Z): Centralised class rules in `apps/web/src/lib/osm-policy.mjs:1`, used by `apps/web/scripts/export-osm.mjs:7` and `apps/web/src/lib/classify.ts:12`. Ranked mapped areas and capped abundant classes to two per resolution-3 H3 region in `apps/web/scripts/export-osm.mjs:192`. The cached Caucasus rebuild in `apps/web/src/osm/Caucasus.geojson:1` now has 107 points: 45 factories, 27 large power plants, three refineries, 16 ports, nine fuel sites, two command sites and five military depots; no weather radar.
- **codex** (2026-09-21T21:03:18.000Z): Found 12 previous candidate midpoints outside their OSM footprints and fixed placement with `pointOnFeature` at `apps/web/scripts/export-osm.mjs:164`; all 107 current exported points are now on-source. `apps/web/scripts/check-osm-candidates.mjs:1` passes 23 policy cases and validates every exported kind and regional cap. `apps/web/README.md:145` documents the rules. Web type-check (zero warnings), production build and mission-roster test pass. Ready for human review; live browser/DCS acceptance remains separate.
