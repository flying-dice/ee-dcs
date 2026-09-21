# EE&nbsp;-&nbsp;DCS — Campaign Generator

The **published web app** for building Enemy Engaged: Comanche vs Hokum campaigns for DCS
World. **This site is how you get mission files** — there's nothing to install and no build
step: open it, design a theatre on a real-world map, and download a ready-to-play `.miz`.

> **Deployment target:** GitHub Pages at `https://flying-dice.github.io/ee-dcs/`.

You pick a DCS theatre, paint resolution-6 H3 cells BLU or RED as rear or close
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
   The map frames that active area, and every DCS airfield is
   plotted as a hollow phosphor **ring** with its name. A projection badge shows whether the
   theatre's DCS-extracted projection is self-consistent (e.g. `projection ✓ 0.0 m`), or
   `unvalidated` if the theatre file carries no anchors.
   Choose **BLU** or **RED**, give the brush a **Rear** or **Close** role, then drag over
   resolution-6 H3 cells. Erase clears cells. Turn painting off to pan the map.
   Close territory has a stronger fill so the forward area remains obvious at a glance.
2. **Set each side's main airbase.** Airbases inside an assigned region automatically belong
   to that side. Toggle **BLUE main** / **RED main**, then click one of that side's DCS airbase
   **rings**. The chosen airfield is highlighted (★) and force-included as the primary base.
3. **Populate keysites.** Enabled once both sides have territory and a valid main airbase.
   Click **Populate keysites** to build a balanced network from the already-loaded export —
   **airbases are real DCS
   airfields** (owned by their containing territory, mains forced), **support sites come from
   OpenStreetMap**, while generated FARPs are distributed directly inside the side's assigned
   Close painted H3 cells. FARP placement does not depend on OSM land-use coverage.
   Role is a hard placement rule: **FARPs and radar use Close territory**; **factories,
   refineries, ports, power, command, supply depots and fuel depots use Rear territory**.
   Airbases may be in either role.
   A requested count deliberately underfills when its side has too few valid candidates.
   Location-tied keysites keep their real positions and take the side and role of the
   containing painted cell. Counts default to an EECH-shaped warzone:
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
     hover-tooltips its underlying data. Potential OSM locations remain visible in every
     mode; DCS airbases remain visible too.
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

The app is a static site (relative `base`), so `dist/` can be served from an HTTP static
host at the root or under a subfolder. Opening it over `file://` is unsupported because
the browser fetches the compressed OSM asset.

### Publishing

The delivery model is the **hosted site**: the GitHub Pages workflow builds and deploys
`dist/` when `main` changes. Users never clone or build — they visit the URL, generate a
theatre, and download the `.miz`. The campaign Lua is baked into each download, so the
hosted site is a complete distribution channel on its own. The workflow checks that every
theatre has a paired compressed OSM export before publishing.

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
- `public/osm/*.geojson.gz` — one compressed, static OSM feature collection with the same theatre id;
  it includes eligible keysite candidates within the active map area. The browser decodes
  gzip automatically or with its native decompressor. Each candidate has
  top-level `kind` (the campaign keysite type) and `name` properties for map inspection.
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
   the DCS theatre polygon, filters the supported keysite tags, and writes the
   paired `public/osm/<Id>.geojson.gz`. Explicit facilities plus industrial-area and warehouse
   spawn sites within the airfield-based active map area are retained. The regional PBF is cached under
   `.osm-work` for fast reruns. To rebuild just the compact output from the cached
   `filtered.geojson` without Docker or the planet
   file, run the same command with `--from-cache` after the theatre id.
   Small components (piers, storage tanks, substations, ordinary fuel stations,
   military bunkers and checkpoints) are intentionally not candidates.
   Ports require a named port or ferry-terminal area, not a pier or ferry stop point.
   Power candidates include named generating plants with documented electrical
   output of at least 100 MW and substation areas with a documented voltage of
   at least 220 kV. Small distribution sites, individual transformers, and plants
   without a capacity tag are omitted from the power class.
   Refineries require an explicit refinery tag or refinery-identifying name; oil
   depots and terminals are fuel candidates instead. Factories require an explicit
   factory tag, a named works with a stated product, or an industrial-land area.
   Warehouse-tagged sites are depot candidates, including unnamed warehouses;
   warehouse tags take precedence over generic industrial land. Unspecified works
   and service facilities are omitted. Ports
   must be harbour or ferry-terminal areas, or named maritime port areas; inland
   dry ports and airport facilities are excluded. Radar requires a radar station
   or radar facility tag, so a weather-radar tower is not treated as military radar.
   Command candidates include named military bases, naval bases, barracks and
   otherwise untyped military land areas. Explicit military-base candidates are preserved.
   Civic command options include town halls, named civic centres and substantial
   government offices/buildings (at least 750 m² for town halls, 1,500 m² for
   the others). Airfields, ranges,
   danger areas and abandoned military sites do not become command dots.
   No candidate class has a geographic cap or nearby-site deduplication. Every
   active-area industrial-land polygon is exported as its own point. A type
   with no credible OSM candidate is left unfilled rather than inventing a dot.
   Exported dots are placed near the centre of their source feature, falling back
   to an on-footprint point if the centre lies outside an irregular polygon. Where
   a mapped site footprint contains same-kind building or point features, the site
   centre wins and those component dots are omitted. Distinct and nested site
   footprints are retained; the dots represent possible spawn sites, not buildings.
   Display names prefer the source's `name:en`, then `official_name:en` or `int_name`,
   then its original `name`. When the display name differs, `sourceName` preserves
   the original in the GeoJSON popup; no names are machine-translated.
4. Rebuild (`npm run build`). The new theatre appears in the dropdown automatically, and
   its projection badge reflects the baked anchors.

Run `npm run test:osm --workspace dcs-eech-mapgen` to check classification examples,
exported kinds and (when the filtered cache is present) complete industrial-polygon coverage.

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
