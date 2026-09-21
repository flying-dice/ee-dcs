# Campaign TypeScript migration and OSM output

- Goal / health: The TypeScript campaign port and web generator pass offline checks; live DCS acceptance remains outstanding. Territory uses one H3 resolution-5 paintbrush level rather than administrative borders.
- Now: [The H3 resolution-5 change](boards/project-backlog/24-use-h3-resolution-5.md) is implemented and verified offline. The compressed Caucasus OSM export and Pages deployment work are complete.
- Next: Exercise the map and brush in-browser, then review strategic-site distribution on the visible terrain.
- Later: No credible military radar is tagged in the current Caucasus source, so automatic radar remains unfilled rather than using a weather radar. Revisit if better source data or an authored fallback is available. [Road-graph card](boards/project-backlog/11-road-graph-from-osm-close-structural-limits.md) is separate; OSM place enrichment may need its own future export. Remove original Lua only after live validation.
- Blocker: DCS Studio tools are not registered in this session and the configured local MCP endpoint is not listening; offline verification cannot establish live DCS acceptance.
- Working state: 2026-09-21 22:55 BST, branch `feat/ts-port-validated-lua-removed`. H3 resolution-5 change committed locally; no push requested.

See [sprint](docs/bots/sprints/2026-09-20-sprint-01.md).
