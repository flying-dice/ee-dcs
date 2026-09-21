---
column: review
labels: [backend, ux]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:48:00.000Z
---
# Prefer compound centres over component buildings

Treat mapped sites as possible spawn locations rather than attributing individual buildings. See [Decision 08](../../decisions/08-site-footprint-centres.md).

## Checklist

- [x] Use the centre of a site polygon, with an on-footprint fallback
- [x] Suppress same-kind building and point candidates inside that site
- [x] Preserve distinct site footprints, other candidate kinds and industrial coverage
- [x] Rebuild and verify candidate counts

## Comments

- **codex** (2026-09-21T21:48:00.000Z): Site-footprint precedence removed 353 component dots from the active export. All 8,227 active-area industrial polygons remain represented, and OSM tests, type-check and build pass.
