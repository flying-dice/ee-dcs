---
status: Accepted
date: 2026-09-21
---
# Decision 02 — One spawn type per industrial or warehouse site

## Context

The generator places spawned campaign facilities at selected sites; the OSM footprint need not already contain a real factory or military depot. Explicit facility tags alone leave uneven coverage. `landuse=industrial` can cover factories, warehouses and workshops, so it is a plausible generic anchor rather than a literal facility type.

## Decision

Export each industrial polygon once at a point near the centre of its footprint. When no more-specific facility class applies, classify it as a factory candidate. Classify warehouse-tagged sites as depot candidates, with warehouse taking precedence over generic industrial land. Keep exact site classes for explicit power, refinery, fuel, port, command and radar facilities. Decision 04 supersedes the original geographic thinning rule: all eligible source footprints remain candidates.

## Consequences

Each dot has one spawn kind. Export and browser must agree on it. Complete OSM re-extraction is needed because the prior filtered cache omitted many generic industrial areas and warehouse tags.
