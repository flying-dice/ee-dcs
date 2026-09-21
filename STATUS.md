# Campaign TypeScript migration and OSM output

- Goal / health: The TypeScript campaign port and web generator pass offline checks; live DCS acceptance remains outstanding. Territory assignment now uses a fixed resolution-6 H3 paintbrush rather than administrative borders.
- Now: The Caucasus OSM export is a 350 KB static gzip asset containing 10,533 active-area candidates. Site polygons take precedence over same-kind component buildings, while all 8,227 active-area industrial polygons remain. The asset, reader and exporter have passed checks and are committed together.
- Next: Exercise the map and H3 brush in-browser, then review the strategic-site distribution on the visible terrain.
- Later: No credible military radar is tagged in the current Caucasus source, so automatic radar remains unfilled rather than using a weather radar. Revisit if better source data or an authored fallback is available. [Road-graph card](boards/project-backlog/11-road-graph-from-osm-close-structural-limits.md) is separate; OSM place enrichment may need its own future export. Remove original Lua only after live validation.
- Blocker: DCS Studio tools are not registered in this session and the configured local MCP endpoint is not listening; offline verification cannot establish live DCS acceptance.
- Working state: 2026-09-21 22:48 BST, branch `feat/ts-port-validated-lua-removed`. The old uncompressed OSM asset was removed after round-trip verification. Local changes were committed without a push; unrelated user changes are preserved.

See [sprint](docs/bots/sprints/2026-09-20-sprint-01.md).
