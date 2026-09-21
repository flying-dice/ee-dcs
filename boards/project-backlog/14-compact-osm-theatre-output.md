---
column: review
labels: [perf, frontend]
priority: med
agent: codex
live: false
updatedAt: 2026-09-21T20:31:39.000Z
---
# Compact the OSM theatre output to current consumers

Keep only selectable keysite points within the active airfield envelope. OSM objective anchors, administrative boundaries, OSM airbase/FARP candidates, and unused source metadata are not consumed by the current generator; the road-graph work in card 11 remains separate.

## Checklist

- [x] Trace current keysite and territory consumers
- [x] Restrict export and rebuild the Caucasus asset from cached raw geometry
- [x] Verify output classifications, web types, and production build
- [x] Remove low-value icon rules and retain Naval Station as the sole nearby port candidate
- [x] Give every retained dot a `kind` and `name` for map inspection
- [x] Rebuild the asset and verify candidate counts and web checks

## Comments

- **codex** (2026-09-21T20:12:48.000Z): Scoped the exporter to current non-airbase/non-FARP classifications and clipped district geometry to the active envelope in `apps/web/scripts/export-osm.mjs:45`; adapted the loader to derive point names from retained tags and omit unused district tags in `apps/web/src/lib/osm.ts:38` and `apps/web/src/lib/types.ts:191`. The cached Caucasus rebuild in `apps/web/src/osm/Caucasus.geojson:1` is 5,365,031 bytes with 27,603 classified points and 341 boundaries, down from 50,370,645 bytes and 257,792 features. Documented the command and scope in `apps/web/README.md:112`. Web check and build pass; all output points classify to a consumed keysite type.
- **codex** (2026-09-21T20:21:05.000Z): Reopened after screenshot feedback. The named Naval Station is area `a407808590` tagged `amenity=ferry_terminal` in `apps/web/.osm-work/Caucasus/filtered.geojson:1`; nearby icons come from two pier areas and a duplicate ferry point. Tightening both `apps/web/src/lib/classify.ts:54` and `apps/web/scripts/export-osm.mjs:45` so the export and map agree on strategic candidates.
- **codex** (2026-09-21T20:25:46.000Z): Restricted `apps/web/src/lib/classify.ts:54` and `apps/web/scripts/export-osm.mjs:45` to named, explicit site tags; exact way/area duplicates are removed. `apps/web/src/osm/Caucasus.geojson:1` now has 633 point candidates and 341 districts in 832,628 bytes. At the screenshot harbor, only `a407808590` remains, with `kind: port` and `name: Naval Station`. `apps/web/src/lib/osm.ts:49` loads and validates the baked kind against browser classification. All 633 points have names and kinds, all kinds match, web type-check and build pass. `apps/web/README.md:112` documents the narrower rules. Fuel has no automatic candidates yet and needs careful reintroduction.
- **codex** (2026-09-21T20:31:39.000Z): Follow-up on English names: `apps/web/scripts/export-osm.mjs:31` now prefers source `name:en`, then `official_name:en` or `int_name`, while preserving a differing original as `sourceName`. The rebuilt `apps/web/src/osm/Caucasus.geojson:1` keeps English names for all 104 points with `name:en`, adds three international-name fallbacks, and leaves names without an English/international tag untouched. `apps/web/README.md:140` documents the policy. Web type-check and build pass.
- **codex** (2026-09-21): H3 painting superseded districts, so the refreshed export omits administrative boundaries. Power is now restricted to named plants with `plant:output:electricity` of at least 100 MW. The Caucasus asset has 421 points (36 power), 120,670 bytes; the browser classifier accepts every exported kind. Potential sites remain visible on the map in all modes.
