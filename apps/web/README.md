# EE&nbsp;-&nbsp;DCS — Campaign Generator

The **published web app** for building Enemy Engaged: Comanche vs Hokum campaigns for DCS
World. **This site is how you get mission files** — there's nothing to install and no build
step: open it, design a theatre on a real-world map, and download a ready-to-play `.miz`.

> **Live site: https://ee-dcs.pages.dev/**

You pick a DCS theatre, assign its administrative regions to BLU or RED as rear or close
territory, choose each side's main airbase, and the app writes a `.miz`
carrying one **trigger zone per keysite** — exactly what the [EECH campaign port](../CLAUDE.md)
reads at runtime to boot an AI-vs-AI dynamic campaign.

By default the generated `.miz` **ships the campaign Lua inside it** and wires it to run at
mission start, so the file is directly playable — open it in DCS and the campaign boots. If
you'd rather author the scripting yourself, untick **Ship campaign Lua** for a zones-only
mission (see [the loop back to the campaign](#the-loop-back-to-the-campaign)).

The mission roster assigns all runtime spawns and baked player slots to Combined Joint
Task Forces Blue and Red.

## What you draw (the flow)

The left panel walks you through the designer flow top to bottom. A hint line always tells
you what a click does right now.

1. **Pick a terrain.** Choose a DCS theatre from the dropdown. The browser merges the
   matching DCS and OSM GeoJSON exports without contacting Overpass. Its real (warped) playable
   quad is drawn as a translucent overlay. The selectable active area is the bounding box around
   all DCS airfields plus a 100 km buffer, which removes the large unused edges found in DCS maps.
   Administrative regions are clipped to that active area, the map frames it, and every DCS airfield is
   plotted as a hollow phosphor **ring** with its name. A projection badge shows whether the
   theatre's DCS-extracted projection is self-consistent (e.g. `projection ✓ 0.0 m`), or
   `unvalidated` if the theatre file carries no anchors.
   Simplified administrative boundaries are also drawn. Click one to open an assignment
   dialog, choose **BLU** or **RED**, and give it a **Rear** or **Close** role. Clear the
   assignment from the same dialog when the region should not participate in the scenario.
   Close territory uses diagonal hazard stripes so the forward area remains obvious at a glance.
2. **Set each side's main airbase.** Airbases inside an assigned region automatically belong
   to that side. Toggle **BLUE main** / **RED main**, then click one of that side's DCS airbase
   **rings**. The chosen airfield is highlighted (★) and force-included as the primary base.
3. **Populate keysites.** Enabled once both sides have territory and a valid main airbase.
   Click **Populate keysites** to build a balanced network from the already-loaded export —
   **airbases are real DCS
   airfields** (owned by their containing territory, mains forced), **support sites come from
   OpenStreetMap**, while generated FARPs are distributed directly inside the side's assigned
   Close administrative territories. FARP placement does not depend on OSM land-use coverage.
   Role is a hard placement rule: **FARPs and radar use Close territory**; **factories,
   refineries, ports, power, command, supply depots and fuel depots use Rear territory**.
   Airbases may be in either role.
   A requested count deliberately underfills when its side has too few valid candidates.
   Location-tied keysites keep their real positions and take the side and role of the
   containing assigned region. Counts default to an EECH-shaped warzone:
   basing-dominant (≈4 airbases + 5 FARPs/side) with **sparse** strategic sites (≈2
   factories, 1 each of refinery/port/radar/power/command/depot/fuel) — EECH places each strategic
   keysite from a single terrain marker, so a campaign has a couple of factories, not a
   grid of them. All ten zone types recognized by the campaign runtime are available.
   Then tune it:
   - **Per-type counts** — a `BLU`/`RED` number per keysite type. The network rebuilds live.
   - **⟳ Shuffle** — re-rolls which airfields/sites are picked (seeded; spacing preserved).
   - **Edit on map** — drag a generated FARP by its handle, click a selected site to remove
     it, or click an unpicked airbase ring / OSM dot to add it. A grouped list mirrors the
     selection with per-item remove (×). Manual edits survive shuffles. Every marker
     hover-tooltips its underlying data. Unselected OSM candidates are hidden outside this
     mode; DCS airbases remain visible.
4. **Balance readout.** Per-side airbase / FARP / total counts, with a warning if a side has
   no airbase (Generate stays locked until both sides have ≥ 1).
5. **Generate `.miz`.** **Ship campaign Lua** (ticked by default) bakes the EECH campaign
   bundle into the `.miz` so it plays as-is (~1 MB); untick it for a zones-only file you
   script yourself. Click **Generate .miz** to build and download the mission (e.g.
   `eech-caucasus.miz`). A success line confirms the zone count and what was baked in.
   **Download GeoJSON** exports the generated keysites and projected zones for any GIS tool.

**Reset distribution** clears territory assignments, main airbases and the preview while
keeping the theatre loaded.

## Dev / build

```sh
npm install      # once
npm run dev      # Vite dev server (http://localhost:5173)
npm run check    # svelte-check — must be 0 errors
npm run build    # production build → dist/
npm run preview  # serve the production build
npm run export:osm --workspace dcs-eech-mapgen -- Caucasus # refresh an OSM theatre export
```

The app is a static site (relative `base`), so `dist/` can be served from any static host,
a subfolder, or opened over `file://`.

### Publishing

The delivery model is the **hosted site**: build (`npm run build`) and deploy the resulting
`dist/` to any static host (GitHub Pages, Netlify, Cloudflare Pages, an S3 bucket, …). Users
never clone or build — they visit the URL, generate a theatre, and download the `.miz`. The
campaign Lua is baked into each download, so the hosted site is a complete distribution
channel on its own. It's live on **Cloudflare Pages** at **https://ee-dcs.pages.dev/**.

## Architecture

- `src/App.svelte` — owns all designer state and wiring; computes the live preview and
  drives the download.
- `src/components/MapView.svelte` — the Leaflet canvas and every drawing interaction.
  Vector layers only (rectangle / polyline / circleMarker / circle) — no default marker
  icons, so there is no bundler icon-path breakage. Clickable markers (airbase rings + OSM
  dots) render on a dedicated SVG pane above the canvas so overlays never swallow clicks.
- `src/components/ControlPanel.svelte` — the numbered left panel (presentation + events).
- `src/lib/*` — the pure pipeline, each module independently unit-shaped:
  `terrains` → `osm` → `classify` → `territory` → `balance` → `projection` → `miz`. **Do not edit these
  from the UI layer;** the UI only imports from them.
- `src/theatres/*.geojson` — one baked theatre extraction per DCS map.
- `src/osm/*.geojson` — one pre-exported OSM feature collection with the same theatre id;
  it includes objective/keysite points and simplified district-level administrative boundaries.
- `src/generated/campaign-bundle.lua` — the EECH campaign bundle, mirrored from the
  repo-root build output (`../dist/ee-dcs.lua`) by
  `scripts/sync-campaign.mjs`, which runs automatically before `dev`/`build`/`check`.
  Git-ignored and lazy-loaded (its own chunk), it's what `miz.ts` embeds when shipping the
  Lua. Rebuild the campaign (DCS Studio: `lua-cargo build`) to refresh the bytes that ship.

Pipeline: `terrain airbases + assigned territories + mains + OSM points → buildKeysites
(per-type counts, seeded shuffle, add/remove) → projected trigger zones → .miz`.

## Adding a terrain

Theatres are data, not code — no rebuild logic changes needed:

1. In DCS, run `tools/dcs-export/theatre.lua` (see that script's header) on the target map.
   It writes a GeoJSON `Feature` carrying the map's real (warped) extent polygon, its
   center, and a **proj4 string extracted from DCS itself** (so projecting a lat/lon
   reproduces the game's own `convertLatLonToMeters`), plus self-validation anchors.
2. Drop the resulting `<Id>.geojson` into `src/theatres/`.
3. Put a current planet file at `E:\planet-latest.osm.pbf` (or set `OSM_PLANET_PATH`), start
   Docker, and run `npm run export:osm --workspace dcs-eech-mapgen -- <Id>`. Osmium extracts
   the DCS theatre polygon, filters the supported objective/keysite tags, and writes the
   paired `src/osm/<Id>.geojson`. Turf simplifies the retained administrative boundaries. The
   current Caucasus export treats OSM `admin_level=6` relations as its district-level
   layer while preserving the source level and tags. The regional PBF is cached under
   `.osm-work` for fast reruns.
4. Rebuild (`npm run build`). The new theatre appears in the dropdown automatically, and
   its projection badge reflects the baked anchors.

## Data sources & attribution

- **Map tiles:** standard OpenStreetMap raster tiles
  (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`).
  Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors.
- **Feature data:** checked-in theatre GeoJSON exported ahead of time from a local
  OpenStreetMap planet PBF with Docker/Osmium, using only the tags consumed by the generator.
  The deployed browser never queries Overpass or another OSM data service.

## The loop back to the campaign

Every generated `.miz` carries a **trigger zone per keysite** — a zone's **colour** sets
the side (`blue = {0,0,1}` / `red = {1,0,0}`) and the **first word of its name** sets the
keysite type (`airbase`, `farp`, `factory`, …). From those zones the port discovers
airbases from the map and boots the full EECH high-level AI (strikes, recon, reaction
chains, ground frontline, helicopter war, logistics, win condition).

**Campaign Lua shipped (default).** The `.miz` embeds the campaign bundle as
`l10n/DEFAULT/ee-dcs.lua` and sets the mission's initialization script to run
it at start (via a `mapResource` ResKey — the same wiring the Mission Editor's
`DO SCRIPT FILE` mission-init writes). Just open the `.miz` in DCS and start it; the
campaign runs. You can still open it in the Mission Editor first to tweak zones by hand
(move, add, recolour, rename) — the campaign re-reads them at runtime.

**Zones-only (unticked).** The `.miz` holds just the zones. Add the campaign yourself —
the port's `dist/ee-dcs.lua` via a `DO SCRIPT FILE` trigger, or inject it live
with the DCS Studio bridge — then start the mission.
