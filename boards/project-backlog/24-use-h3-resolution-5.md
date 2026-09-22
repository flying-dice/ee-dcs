---
column: review
labels: [frontend, feature]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:55:00.000Z
---
# Use H3 resolution 5 for territory painting

The resolution-6 brush is too granular. Keep a single fixed level, now H3 resolution 5, throughout painting, ownership lookup, generation and map copy. See [Decision 09](../../decisions/09-h3-resolution-5.md).

## Checklist

- [x] Change the shared territory resolution and inspect all consumers
- [x] Update visible copy and documentation
- [x] Verify type-check, tests and production build
- [x] Commit the change

## Comments

- **codex** (2026-09-21T21:54:00.000Z): `apps/web/src/lib/territory.ts:14` owns the fixed H3 level; `apps/web/src/components/MapView.svelte:110` uses that constant for grid, hover and click. Explicit resolution-6 text remains in `apps/web/src/components/ControlPanel.svelte:74`, `apps/web/src/components/Manual.svelte:335`, `apps/web/README.md:9` and `apps/web/src/lib/types.ts:194`. There is no persisted territory state; `apps/web/src/App.svelte:25` starts with an empty assignment map.
- **codex** (2026-09-21T21:55:00.000Z): Changed `apps/web/src/lib/territory.ts:14` to level 5 and updated `apps/web/src/components/ControlPanel.svelte:74-78`, `apps/web/src/components/Manual.svelte:335`, `apps/web/src/lib/types.ts:194` and `apps/web/README.md:9-36`. Grid, hover, click and ownership lookup already share the constant. Type-check, web build, mission test and OSM test pass; clean-code review found no new violations. No browser interaction was run.
