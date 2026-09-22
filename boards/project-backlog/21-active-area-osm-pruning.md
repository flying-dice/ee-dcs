---
column: review
labels: [backend, perf]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:48:00.000Z
---
# Crop OSM candidates to the active map area

Post-process candidate points against the same airfield-based rectangle that the map shows. See [Decision 07](../../decisions/07-active-area-osm-pruning.md).

## Checklist

- [x] Match the UI's 100 km airfield envelope
- [x] Crop after classification and point placement
- [x] Keep every eligible industrial polygon inside the envelope
- [x] Rebuild and verify the compressed export

## Comments

- **codex** (2026-09-21T21:48:00.000Z): The export now has 10,533 active-area site candidates. The test independently checks the rectangle and verifies all 8,227 eligible industrial polygons within it remain present. No region caps or nearby-site deduplication were introduced.
