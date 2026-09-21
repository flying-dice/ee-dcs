---
status: Accepted
date: 2026-09-21
---
# Decision 10 — Versioned GeoJSON design saves

## Context

The zones download is useful for inspection but cannot resume editing. Designers need to save and reopen a complete campaign design.

## Decision

Export a GeoJSON FeatureCollection with painted H3 cells as Polygon features and selected keysites as Point features. The territory features are authoritative for cell assignments; versioned collection metadata holds the non-spatial generator state. Import validates the format, H3 resolution, terrain, counts and overrides before changing the current session, then loads that theatre's OSM data and restores the controls. Reject unsupported versions and incompatible resolution instead of silently discarding data.

## Consequences

The file remains viewable in GIS tools while supporting an exact round-trip with the same application and OSM dataset. Selected-site points are a preview; balancing inputs and manual edits determine the restored roster.
