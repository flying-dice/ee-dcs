# DCS theatre export

Scripts that run **inside DCS** to extract a theatre's real geometry + projection, so
the web map-generator (`web/`) can overlay it and project lat/lon → DCS metres exactly
as the game does (self-consistent with the terrain's warp — no assumed WGS84).

## How to run

1. Open **DCS Fiddle** (or any DCS Lua console with a GUI-environment option).
2. Load the target map — open a mission on it in the Mission Editor, or run a mission.
3. **`theatre.lua`** → select the **GUI environment**, paste, run. It returns a GeoJSON
   `Feature` (map-extent polygon + `properties.projection.proj` proj4 string + UTM +
   self-validation anchors). Save the returned JSON as `web/src/theatres/<Id>.geojson`.
4. **`airbases.lua`** → select the **mission/server environment** (needs `world.getAirbases`,
   so a mission must be running), paste, run. It returns a GeoJSON `FeatureCollection` of
   airbase + parking points. Optional overlay; save as `web/src/theatres/<Id>.airbases.geojson`.

After dropping the `.geojson` into `web/src/theatres/`, rebuild the web app — the theatre
appears in the picker automatically (the app globs that folder). No code change needed.

## Why extract from DCS rather than hardcode params

DCS terrains are geographically **warped** relative to true WGS84 (up to ~100+ m). The proj4
string here is derived from DCS's own `convertLatLonToMeters` at the map's central meridian,
so feeding a real-world lat/lon through it reproduces where DCS actually places that point.
The baked `anchors` (a 3×3 grid of lat/lon ↔ DCS-metres, both from DCS) let the web app
self-check the projection — Caucasus reproduces to **< 0.001 m**.

MIT licence. See also https://github.com/JonathanTurnock/dcs-projections
