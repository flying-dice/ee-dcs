# ADR 0006: Use DCS stock four-position FARPs

## Status

Accepted, 2026-09-21.

## Context

Campaign helicopter sections were visibly stacked around generated FARPs. The
generated object used `type = "FARP"` with `shape_name = "FARP"`. A Mission
Editor-authored comparison proves that combination selects the small concrete
helipad model. The actual four-pad FARP uses `type = "FARP"` with
`shape_name = "FARPS"`. Dynamic helicopter groups also described the object as
an airdrome and supplied no parking position, so DCS used their raw coordinates.

Installed DCS data provides the authoritative distinction:

- `MissionEditor/modules/me_exportToMiz.lua:895-944` emits
  `TakeOffParking`, `helipadId`, `linkUnit`, and parking identifiers `1` through
  `4` for the stock FARP.
- `CoreMods/tech/SouthAtlanticAssets/Entries/Static/farpsingle.lua` declares
  `FARP_SINGLE_01` with `numParking = 1`.
- The invisible FARP is also a one-position heliport.

The campaign launches two-aircraft attack-helicopter sections, so the one-slot
variants cannot represent its normal operation.

## Decision

Generated campaign FARPs always use the stock four-position object:

```lua
type = "FARP"
shape_name = "FARPS"
category = "Heliports"
```

All helicopter builders pass departures and returns through one DCS adapter.
For a FARP it writes `TakeOffParking`, links the route point with `helipadId`
and `linkUnit`, removes `airdromeId`, moves the group, waypoint and units to the
heliport origin as DCS's exporter does, and assigns the aircraft to positions
`1` through `4`. Actual runway airbases retain `airdromeId` behavior.

## Consequences

- A two-aircraft section occupies two distinct FARP positions; the next section
  rotates onto the remaining two positions.
- A single generated group containing more than four helicopters is rejected
  instead of silently stacking aircraft.
- All attack, escort, troop insertion, supply, BDA, and regeneration helicopter
  spawn paths use the same encoding.
- Existing running missions retain their embedded older bundle. A newly
  generated mission is required to observe the change in DCS.
