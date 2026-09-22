---
column: review
labels: [feature, frontend]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:55:00.000Z
---
# Paint campaign territory on an H3 grid

Replace administrative-border selection with a paintbrush. Every stroke paints or erases one fixed-resolution H3 cell. A painted cell carries BLU/RED ownership and Rear/Close role for airbases, FARPs, radar and support-site generation. The current level is 5; see [Decision 09](../../decisions/09-h3-resolution-5.md).

## Checklist

- [x] Replace polygon territory lookup with H3 cell lookup
- [x] Add fixed-resolution paint/erase controls, hover preview and drag painting
- [x] Keep keysite and FARP placement tied to painted cells
- [x] Remove administrative polygons from the runtime OSM asset
- [x] Update documentation and verify type-check, build and H3/data invariants

## Comments

- **codex** (2026-09-21T20:36:00.000Z): Traced the district assignment flow through `apps/web/src/App.svelte:25`, `apps/web/src/components/MapView.svelte:120`, `apps/web/src/components/ControlPanel.svelte:74`, `apps/web/src/lib/territory.ts:59` and `apps/web/src/lib/balance.ts:85`. Selected H3 resolution 5 as the finest stored level and levels 3–5 for the UI. Installed `h3-js` in `apps/web/package.json:1` after the sandboxed package request was denied by network permissions.
- **codex** (2026-09-21): User narrowed the design to one resolution, then changed it to 6. Removed the dropdown and parent-cell expansion; all painting, lookup and labels now use resolution 6. Export rebuilt from cache with 633 points and no administrative polygons.
- **codex** (2026-09-21): Follow-up keeps all deduplicated potential OSM locations visible, before and after painting. The stricter power rule leaves 421 exported points and 391 map candidates. `svelte-check` passes with zero warnings; production build and classifier/data checks pass. Live map interaction has not yet been manually exercised.
- **codex** (2026-09-21T21:55:00.000Z): User found level 6 too granular. `apps/web/src/lib/territory.ts:14` now fixes the single level at 5, consumed by map painting and lookup in `apps/web/src/components/MapView.svelte:138-147` and `apps/web/src/lib/territory.ts:91`. Current copy in `apps/web/src/components/ControlPanel.svelte:74-78` and `apps/web/README.md:9` matches. See [follow-up card](24-use-h3-resolution-5.md).
