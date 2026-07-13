# DCS theatre export

One script (`theatre-dump.lua`) that runs **inside DCS** to extract a theatre's real
geometry + projection + airbases, so the web map-generator (`web/`) can overlay it and
project lat/lon → DCS metres exactly as the game does (self-consistent with the terrain's
warp — no assumed WGS84).

## How to run

Each theatre is ONE file — `web/src/theatres/<Id>.geojson` — a GeoJSON `FeatureCollection`
holding the **TERRAIN** feature (map-extent polygon + projection + anchors) plus one
**AIRBASE** point per airfield and one **PARKING** point per spot.

The two halves live in different DCS Lua environments — bounds/projection need the GUI/hooks
env (`terrain.GetTerrainConfig`/`convert*`), airbases/parking need the mission env
(`world.getAirbases`/`Airbase.getParking`), and neither env has both. So **`theatre-dump.lua`
runs as a GUI hook**: it computes the TERRAIN feature locally, then pulls the airbases from
the running mission with `net.dostring_in` (which works in a stock, sanitized mission env
because `world`/`Airbase`/`coord` are never sanitized) and writes the file with `io` (hooks
have it). No `MissionScripting.lua` change of any kind.

Install:

1. **Copy `theatre-dump.lua`** into your DCS write dir, e.g.
   `C:\Users\<you>\Saved Games\DCS.openbeta\Scripts\Hooks\theatre-dump.lua`.
2. Restart DCS, then load a mission on each terrain. A few seconds in, an in-mission alert
   names the file it wrote — by default `Saved Games\DCS.openbeta\<Id>.geojson`. Copy that
   into `web/src/theatres/`. (Or set `OUT_DIR` at the top of the file to your
   `web\src\theatres\` path to write there directly — no other setup.)

**No fallback:** if the hooks env can't read the terrain API, nothing is written (never
partial/approximate bounds). `theatre-dump.lua` is the whole tool — one self-contained file
(it embeds the DCS Fiddle JSON encoder/decoder; there are no other scripts to run).

After the `.geojson` is in `web/src/theatres/`, rebuild the web app — the theatre appears
in the picker automatically (the app globs that folder). No code change needed.

## Why extract from DCS rather than hardcode params

DCS terrains are geographically **warped** relative to true WGS84 (up to ~100+ m). The proj4
string here is derived from DCS's own `convertLatLonToMeters` at the map's central meridian,
so feeding a real-world lat/lon through it reproduces where DCS actually places that point.
The baked `anchors` (a 3×3 grid of lat/lon ↔ DCS-metres, both from DCS) let the web app
self-check the projection — Caucasus reproduces to **< 0.001 m**.

MIT licence. See also https://github.com/JonathanTurnock/dcs-projections
