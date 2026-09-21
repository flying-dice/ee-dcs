---
status: Accepted
date: 2026-09-21
---
# Decision 04 — Preserve every eligible OSM candidate

## Context

The user clarified that at least the centre of every `landuse=industrial` polygon must appear, and that no class should be capped or deduplicated by broad map region. Earlier regional quotas and the browser's 300 m proximity collapse could hide distinct source features.

## Decision

Export all classified OSM features whose representative point falls inside the theatre polygon. Do not clip to the airfield envelope, impose H3 regional quotas or collapse nearby but distinct source features. Keep the mechanical Osmium closed-way line/area duplicate removal, which prevents two records for the same OSM way. For polygons, use a centre-of-mass point when it lies inside the footprint and an on-footprint point otherwise. Render visible dots on a canvas and redraw them as the map viewport moves.

## Consequences

The Caucasus export grows substantially, but every eligible industrial polygon is inspectable as its own dot. The generator still chooses only the configured number of spawn sites from the candidates inside painted territory. Geographic variety now comes from the complete candidate pool and the authored territory, not from export-time regional thinning.
