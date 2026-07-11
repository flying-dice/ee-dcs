# DCS EECH Map Generator

A browser tool that turns a **real-world region** into a **balanced EECH-campaign DCS
mission**. You pick a DCS theatre, draw a box over any part of the real map, pull in real
infrastructure from OpenStreetMap, split the map into two sides with a frontline, and the
tool writes a `.miz` carrying one **trigger zone per keysite** — exactly what the
[EECH campaign port](../CLAUDE.md) reads at runtime to boot an AI-vs-AI dynamic campaign.

By default the generated `.miz` **ships the campaign Lua inside it** and wires it to run at
mission start, so the file is directly playable — open it in DCS and the campaign boots. If
you'd rather author the scripting yourself, untick **Ship campaign Lua** in step 7 for a
zones-only mission (see [the loop back to the campaign](#the-loop-back-to-the-campaign)).

## What you draw (the flow)

The left panel walks you through the designer flow top to bottom. A hint line always tells
you what a click does right now.

1. **Pick a terrain.** Choose a DCS theatre from the dropdown. Its real (warped) playable
   quad is drawn as a translucent overlay, the map frames it, and every DCS airfield is
   plotted as a hollow phosphor **ring** with its name. A projection badge shows whether the
   theatre's DCS-extracted projection is self-consistent (e.g. `projection ✓ 0.0 m`), or
   `unvalidated` if the theatre file carries no anchors.
2. **Draw the theatre-area bbox.** Click **Draw bbox**, then drag a rectangle on the map.
   It validates live: **green** `inside terrain ✓` when every corner is inside the theatre
   quad, **red** `outside terrain — redraw` otherwise. The next steps stay locked until the
   bbox is valid.
3. **Draw the frontline.** Click **Draw frontline**, then click to drop vertices; finish
   with a double-click, the **Finish** button, or **Enter**. The line splits the theatre
   into a BLUE and a RED half.
4. **Set each side's main airbase.** Toggle **BLUE main** / **RED main**, then click a DCS
   airbase **ring** on the map. The chosen airfield is highlighted (★) and force-included as
   that side's primary base; its ring's side of the frontline decides which half is BLUE.
5. **Populate keysites.** Enabled once the frontline and both mains exist. Click **Populate
   keysites**: the tool runs one bounded [Overpass](https://overpass-api.de/) query for
   FARPs + support infrastructure, then builds a balanced network — **airbases are real DCS
   airfields** (split by the frontline, mains forced), **FARPs + support sites come from
   OpenStreetMap**. Placement is EECH-faithful: EECH puts each keysite at its **real map
   location** and colors it by **which side's territory it sits in** — no front/rear or
   depth bias (`get_initial_sector_side`, popread.c). Here the drawn frontline is that
   territory boundary, so every keysite keeps its true position and takes the side of the
   line it falls on; the counts just cap how many of the most prominent real features of
   each type are kept per side. Counts default to an EECH-shaped warzone:
   basing-dominant (≈4 airbases + 5 FARPs/side) with **sparse** strategic sites (≈2
   factories, 1 each of refinery/port/radar/power/command) — EECH places each strategic
   keysite from a single terrain marker, so a campaign has a couple of factories, not a
   grid of them. The eight types are EECH's land keysite variants; `fuel` and `depot`
   aren't separate EECH keysites (they fold into refinery/command), so the tool doesn't
   emit them. Then tune it:
   - **Per-type counts** — a `BLU`/`RED` number per keysite type. The network rebuilds live.
   - **⟳ Shuffle** — re-rolls which airfields/sites are picked (seeded; spacing preserved).
   - **Edit on map** — click a selected site to remove it, or an unpicked airbase ring / OSM
     dot to add it. A grouped list mirrors the selection with per-item remove (×). Manual
     add/remove survive shuffles. Every marker hover-tooltips its underlying data.
6. **Balance readout.** Per-side airbase / FARP / total counts, with a warning if a side has
   no airbase (Generate stays locked until both sides have ≥ 1).
7. **Generate `.miz`.** **Ship campaign Lua** (ticked by default) bakes the EECH campaign
   bundle into the `.miz` so it plays as-is (~1 MB); untick it for a zones-only file you
   script yourself. Click **Generate .miz** to build and download the mission (e.g.
   `eech-caucasus.miz`). A success line confirms the zone count and what was baked in.
   **Download GeoJSON** exports the frontline + keysites + projected zones for any GIS tool.

**Reset drawings** clears the frontline / main airbases / preview but keeps the terrain and
bbox, so you can re-split the same region without reloading data.

## Dev / build

```sh
npm install      # once
npm run dev      # Vite dev server (http://localhost:5173)
npm run check    # svelte-check — must be 0 errors
npm run build    # production build → dist/
npm run preview  # serve the production build
```

The app is a static site (relative `base`), so `dist/` can be served from any static host,
a subfolder, or opened over `file://`.

## Architecture

- `src/App.svelte` — owns all designer state and wiring; computes the live preview and
  drives the download.
- `src/components/MapView.svelte` — the Leaflet canvas and every drawing interaction.
  Vector layers only (rectangle / polyline / circleMarker / circle) — no default marker
  icons, so there is no bundler icon-path breakage. Clickable markers (airbase rings + OSM
  dots) render on a dedicated SVG pane above the canvas so overlays never swallow clicks.
- `src/components/ControlPanel.svelte` — the numbered left panel (presentation + events).
- `src/lib/*` — the pure pipeline, each module independently unit-shaped:
  `terrains` → `osm` → `classify` → `balance` → `projection` → `miz`. **Do not edit these
  from the UI layer;** the UI only imports from them.
- `src/theatres/*.geojson` — one baked theatre extraction per DCS map.
- `src/generated/campaign-bundle.lua` — the EECH campaign bundle, mirrored from the
  repo-root build output (`../dist/dynamic-mission-test.lua`) by
  `scripts/sync-campaign.mjs`, which runs automatically before `dev`/`build`/`check`.
  Git-ignored and lazy-loaded (its own chunk), it's what `miz.ts` embeds when shipping the
  Lua. Rebuild the campaign (DCS Studio: `lua-cargo build`) to refresh the bytes that ship.

Pipeline: `terrain airbases + frontline + mains + OSM (FARPs/support) → buildKeysites
(per-type counts, seeded shuffle, add/remove) → projected trigger zones → .miz`.

## Adding a terrain

Theatres are data, not code — no rebuild logic changes needed:

1. In DCS, run `tools/dcs-export/theatre.lua` (see that script's header) on the target map.
   It writes a GeoJSON `Feature` carrying the map's real (warped) extent polygon, its
   center, and a **proj4 string extracted from DCS itself** (so projecting a lat/lon
   reproduces the game's own `convertLatLonToMeters`), plus self-validation anchors.
2. Drop the resulting `<Id>.geojson` into `src/theatres/`.
3. Rebuild (`npm run build`). The new theatre appears in the dropdown automatically, and
   its projection badge reflects the baked anchors.

## Data sources & attribution

- **Map tiles:** standard OpenStreetMap raster tiles
  (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`).
  Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors.
- **Feature data:** the [Overpass API](https://overpass-api.de/) (primary endpoint with a
  mirror fallback), querying only the narrow tag set the classifier recognises — never a
  generic building sweep. Overpass is a shared public service; keep bbox sizes reasonable.

## The loop back to the campaign

Every generated `.miz` carries a **trigger zone per keysite** — a zone's **colour** sets
the side (`blue = {0,0,1}` / `red = {1,0,0}`) and the **first word of its name** sets the
keysite type (`airbase`, `farp`, `factory`, …). From those zones the port discovers
airbases from the map and boots the full EECH high-level AI (strikes, recon, reaction
chains, ground frontline, helicopter war, logistics, win condition).

**Campaign Lua shipped (default).** The `.miz` embeds the campaign bundle as
`l10n/DEFAULT/dynamic-mission-test.lua` and sets the mission's initialization script to run
it at start (via a `mapResource` ResKey — the same wiring the Mission Editor's
`DO SCRIPT FILE` mission-init writes). Just open the `.miz` in DCS and start it; the
campaign runs. You can still open it in the Mission Editor first to tweak zones by hand
(move, add, recolour, rename) — the campaign re-reads them at runtime.

**Zones-only (unticked).** The `.miz` holds just the zones. Add the campaign yourself —
the port's `dist/dynamic-mission-test.lua` via a `DO SCRIPT FILE` trigger, or inject it live
with the DCS Studio bridge — then start the mission.
