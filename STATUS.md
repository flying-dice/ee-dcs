# Campaign TypeScript migration and OSM output

- Goal / health: The TypeScript campaign port and web generator pass offline checks; live DCS acceptance remains outstanding. Territory uses one H3 resolution-5 paintbrush level rather than administrative borders.
- Now: [GeoJSON design save/import](boards/project-backlog/25-import-export-design-geojson.md) passes lint, type-check, tests and build; the user confirmed the browser flow. H3-5 is the first published format. Open PR #1 is ready for a fresh review of the branch.
- Next: Review PR #1, then revisit strategic-site distribution on the visible terrain.
- Later: No credible military radar is tagged in the current Caucasus source, so automatic radar remains unfilled rather than using a weather radar. Revisit if better source data or an authored fallback is available. [Road-graph card](boards/project-backlog/11-road-graph-from-osm-close-structural-limits.md) is separate; OSM place enrichment may need its own future export. Remove original Lua only after live validation.
- Blocker: DCS Studio tools are not registered in this session and the configured local MCP endpoint is not listening; offline verification cannot establish live DCS acceptance.
- Working state: 2026-09-21 23:15 BST, branch `feat/ts-port-validated-lua-removed`; outgoing checks pass and PR #1 is open. No live DCS acceptance has been performed.

See [sprint](docs/bots/sprints/2026-09-20-sprint-01.md).
