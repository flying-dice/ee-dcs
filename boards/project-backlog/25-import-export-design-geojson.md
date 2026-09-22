---
column: review
labels: [frontend, feature]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T22:15:00.000Z
---
# Import and export the campaign design as GeoJSON

Replace the diagnostic zones download with a versioned, round-trip design file. Painted H3 territory and selected sites remain ordinary GeoJSON features; non-spatial generator choices live in collection metadata. See [Decision 10](../../decisions/10-geojson-design-save.md).

## Checklist

- [x] Serialize and validate complete design state
- [x] Wire safe import/export controls into the generator
- [x] Test round-trip and malformed/incompatible files
- [x] Update usage documentation and verify app checks

## Comments

- **codex** (2026-09-21T22:01:00.000Z): `apps/web/src/App.svelte:140` currently writes selected keysite points and DCS zones, but no painted cells or balancing inputs; `apps/web/src/components/ControlPanel.svelte:99` has export only. The new save must include H3 assignments, mains, counts, seed, manual add/remove/move overrides, aircraft types and the Lua option. Import will validate before replacing state.
- **codex** (2026-09-21T22:07:00.000Z): `apps/web/src/lib/design-geojson.ts:1-185` now writes H3 Polygon and selected-site Point features with versioned generator settings, and validates imported cells and settings. `apps/web/src/App.svelte:141-217` loads the referenced theatre before applying restored state, preserving the current design on error. `apps/web/src/components/ControlPanel.svelte:109-111` exposes Save/Load controls. `apps/web/scripts/check-design-geojson.mjs:1-45` passes round-trip and six invalid-file cases; type-check, production build, mission and OSM tests pass. The user confirmed H3-6 was never published, so no migration is needed. Browser interaction remains untested.
- **codex** (2026-09-21T22:14:00.000Z): The user confirmed the browser flow looks good. A legacy zone-only GeoJSON was also rejected by `apps/web/src/lib/design-geojson.ts:126-129` without changing the selected theatre, as intended for a ground-zero save format. PR #1 is open; final review and push are in progress.
- **codex** (2026-09-21T22:15:00.000Z): Outgoing review found no new high-severity clean-code findings in `apps/web/src/lib/design-geojson.ts:1-185` or the UI wiring in `apps/web/src/App.svelte:145-217`. Biome lint, Svelte type-check, GeoJSON round-trip/invalid-file test, mission-roster test, OSM coverage test and production build all pass. The branch is ready for a fresh review in PR #1.
