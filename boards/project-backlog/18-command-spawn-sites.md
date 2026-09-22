---
column: review
labels: [backend, perf]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:28:00.000Z
---
# Expand command spawn sites

Preserve explicit military-base command sites while adding generic military land areas, barracks, naval bases, civic centres and substantial government buildings as single-dot command candidates. See [Decision 03](../../decisions/03-command-spawn-sites.md).

## Checklist

- [x] Audit all military OSM tag values in the Caucasus extract
- [x] Expand the export filter and single-type classification
- [x] Rebuild the Caucasus asset and verify military/civic distributions
- [x] Run classifier, web and mission regression checks

## Comments

- **codex** (2026-09-21T21:22:00.000Z): The full military-tag audit found many `landuse=military` footprints without `military=base`, alongside thousands of small bunkers, trenches and checkpoints. Generic military-area and civic candidates are separately geographically thinned; explicit named bases retain their existing uncapped selection. The rebuilt export has 221 command candidates across 38 broad H3 regions, including 80 `military=base` and 66 civic candidates; ready for review.
- **codex** (2026-09-21T21:28:00.000Z): Later user instruction removed geographic caps for every kind; command candidates now also remain uncapped. Decision 04 records that override. Explicit military-base classification is unchanged.
