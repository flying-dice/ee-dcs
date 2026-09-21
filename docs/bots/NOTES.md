# Project notes

- Source baseline has 34 modules, despite the supplied plan's count of 32.
- Lua `require` timing is significant in main; configuration validation precedes game-loop dependencies.
- DCS instance methods use colon calls; globals use dot calls.
- Existing developer runbooks contain obsolete module counts and scheduler references; actual code governs this migration.

## Migration handoff

- Root bundle now comes from the ee-mission workspace build. The web sync script copies this root output.
- Deferred configuration and game-loop imports preserve reset/configuration initialization order.
- TSTL multi-variable declarations can evaluate dependent expressions before their apparent prerequisite; the combat dispatch calculation uses separate declarations.
- Persistence intentionally retains the original contiguous numeric dead-registry snapshot behavior. Named boolean entries were already omitted by the Lua baseline; changing this is separate work.
- All 24 differential checks and 310/2100-second simulated runs pass. DCS Studio/live acceptance remains outstanding; do not remove the Lua baseline yet.
- Final hygiene: Biome reports no errors; 20 optional-chain warnings and 48 style suggestions remain. Git whitespace checking reports trailing spaces emitted by TSTL module wrappers in the generated bundle; source changes pass when that generated file is excluded. Generated bundle and web copy have matching hashes.
- Web app follow-up: production build passes; Svelte check reports zero errors/warnings. Browser smoke test loads the production preview, selects Caucasus, shows 21 airfields and enables area drawing; browser warning/error logs are empty. Vite emits a non-blocking size warning for the ~1 MB campaign asset. Full .miz generation was not exercised in this follow-up.
- The web scenario workflow uses explicit administrative-territory assignments. Clicking a boundary opens a modal where the user chooses BLU or RED and Rear or Close; there is no inferred role or automatic depth scoring.
- Theatre data is a paired export contract: `src/theatres/<Id>.geojson` from DCS and `src/osm/<Id>.geojson` from the Docker/Osmium export of the local planet PBF. Theatre selection lazy-loads and merges both; deployed browsers never call Overpass.
- The paired OSM asset also carries simplified `admin-boundary` polygons. Caucasus currently maps OSM `admin_level=6` to its district/ADM2-style layer; retain the source level because OSM hierarchy semantics vary by country. Osmium exports relation polygons as odd-numbered area IDs (`a<2r+1>`), which the exporter converts back to stable `relation/<r>` IDs.
- Administrative assignments are authoritative generation input. Airbases inherit the side of their containing territory; each selected main must be inside matching territory. FARPs and radar require Close territory, while factories, refineries, ports, power, command, supply depots and fuel depots require Rear territory. Airbases may use either role.
- The selectable theatre area is the bounding box of all exported DCS airfields plus a 100 km buffer, clamped to the DCS theatre bounds. Administrative polygons are clipped to this envelope before assignment, so territory ownership and candidate placement cannot extend into the large unused edges of a DCS map.
- Generated FARPs use deterministic interior points distributed across the side's assigned Close administrative territories. Generation no longer depends on OSM land-use surfaces or settlement-clearance masks; spacing progressively relaxes only when necessary to satisfy the requested count within small territories.
- Unselected OSM keysite candidates render only in Edit on map mode; DCS airbases remain visible in every mode.
