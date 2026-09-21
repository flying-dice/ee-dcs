# ADR 0003: Numeric constant provenance

## Context

The campaign combines three numeric domains: DCS API identifiers, values ported from the EECH source, and adapter policy needed to express the campaign in DCS. Unnamed literals made those domains hard to distinguish and allowed a TypeScript ambient enum to compile into a nonexistent Lua global.

## Decision

- Read DCS identifiers through their runtime tables (`coalition.side`, `country.id`, `Object.Category`, `world.event`, `world.VolumeType`, `land.SurfaceType`, `Group.Category`, and `Airbase.Category`). Type declarations describe those tables but must not introduce runtime-looking ambient enums.
- Name mission-format values that do not have a runtime table, including the Mission Editor quadrilateral-zone type, and state the format source beside the constant.
- Name EECH gameplay values with their unit and cite the originating C/header/data file. The local `E:\eech_source_code` tree is authoritative for these values.
- Mark DCS adapter values as adapter policy and state what they control. Differential and smoke tests prove that a refactor preserves the selected behavior; they do not claim that an adapter policy is an original EECH value.
- Keep numbers inside declarative records, such as pylon station lists, payload records, rank tables and configuration defaults, when the field or table already supplies the domain name. Extracting each record cell would obscure the data rather than explain it.
- Give unit conversions (`60` seconds/minute, `1000` metres/kilometre, `100` percent scale) a name when used in gameplay calculations or scheduling.

## Proof

- DCS enum and country values were cross-checked against the installed DCS database/default-coalition files and saved mission tables. The generated Lua is inspected to ensure references remain runtime expressions such as `Object.Category.SCENERY`.
- EECH tuning constants were checked against the cited source in `E:\eech_source_code`.
- Adapter constants retain the values from the preserved Lua implementation and are covered by Lua/TypeScript differential checks or campaign smoke tests.
- The campaign tests exercise zero-valued enums, numeric Lua table keys, scenery-category searches, neutral event initiators, and CJTF country assignment.

Live DCS Studio table inspection is the preferred final check for DCS-owned strings and integers. On 2026-09-21 DCS itself was running, but the configured Studio MCP endpoint at `127.0.0.1:25570/mcp` was not listening, so this audit used the installed database, saved missions, emitted Lua and offline runtime mocks.

## Consequences

Future numeric changes must identify which domain owns the value and carry the corresponding evidence. A change to an adapter policy is a behavior decision and cannot be presented as source parity.
