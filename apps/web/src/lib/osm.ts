// ── OSM / Overpass data source ─────────────────────────────────────────────────
// Fetches the raw geographic features the classifier turns into keysite candidates.
// One bounded Overpass query per bbox, collecting only the tag sets classify.ts keys
// on (aeroway, military, industrial man_made, landuse=industrial/harbour/depot,
// power plants/substations, harbour/port, fuel depots) — never all buildings.
//
// Pipeline position:  bbox → fetchOsm() → OsmFeature[] → classify.ts.

import type { BBox, OsmFeature } from './types';

// Public Overpass endpoints. Primary first; on a network/5xx failure fetchOsm()
// retries once against the mirror.
const OVERPASS_PRIMARY = 'https://overpass-api.de/api/interpreter';
const OVERPASS_MIRROR = 'https://overpass.kumi.systems/api/interpreter';

/**
 * Build one Overpass QL query for the bbox. Uses a global `[bbox:s,w,n,e]` so every
 * statement is implicitly clipped, and `nwr` (node+way+relation) with `out center;`
 * so ways/relations return a centroid we can use as the keysite location.
 *
 * The tag union is deliberately narrow — only what classify.ts recognises — to keep
 * the payload bounded (no generic `building` sweep).
 */
export function buildOverpassQuery(bbox: BBox): string {
  // Overpass bbox order is (south, west, north, east).
  const s = bbox.south;
  const w = bbox.west;
  const n = bbox.north;
  const e = bbox.east;
  const box = `${s},${w},${n},${e}`;

  return [
    `[out:json][timeout:60][bbox:${box}];`,
    '(',
    // airbase / farp candidates
    '  nwr["aeroway"~"^(aerodrome|heliport)$"];',
    // military installations → command/radar/depot
    '  nwr["military"~"^(airfield|radar_station|depot|ammunition|bunker|barracks)$"];',
    // industrial man_made → factory / refinery / radar / power / port / fuel
    '  nwr["man_made"~"^(works|petroleum_refinery|radar|power_station|storage_tank|tank_farm|pier)$"];',
    // industrial / harbour / depot land use → factory / port / depot
    '  nwr["landuse"~"^(industrial|harbour|depot)$"];',
    '  nwr["building"="industrial"];',
    '  nwr["industrial"];', // industrial=oil/refinery/port/... — value inspected in classify.ts
    // ports
    '  nwr["harbour"="yes"];',
    '  nwr["amenity"~"^(ferry_terminal|fuel)$"];',
    // radar (alternate tagging)
    '  nwr["tower:type"="radar"];',
    // power infrastructure
    '  nwr["power"~"^(plant|substation)$"];',
    // command (regional government seats)
    '  nwr["office"="government"];',
    ');',
    'out center;',
  ].join('\n');
}

// One Overpass element as returned in the `elements` array.
interface OverpassElement {
  type: 'node' | 'way' | 'relation';
  id: number;
  lat?: number;
  lon?: number;
  center?: { lat: number; lon: number };
  tags?: Record<string, string>;
}

function toFeature(el: OverpassElement): OsmFeature | null {
  // Node coords live on lat/lon; way/relation centroids on center (from `out center`).
  const lat = el.lat ?? el.center?.lat;
  const lon = el.lon ?? el.center?.lon;
  if (typeof lat !== 'number' || typeof lon !== 'number') return null; // no resolvable point → drop
  const tags = el.tags ?? {};
  return {
    id: `${el.type}/${el.id}`,
    latlon: { lat, lon },
    tags,
    name: tags.name,
  };
}

async function postOverpass(endpoint: string, query: string): Promise<OverpassElement[]> {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
    body: query,
  });
  if (!res.ok) {
    // Signal 5xx (server / rate) so the caller can retry the mirror; 4xx is fatal.
    const retryable = res.status >= 500;
    const err = new Error(`Overpass ${endpoint} returned HTTP ${res.status}`);
    (err as Error & { retryable?: boolean }).retryable = retryable;
    throw err;
  }
  const json = (await res.json()) as { elements?: OverpassElement[] };
  return json.elements ?? [];
}

/**
 * Fetch OSM features for the bbox. Tries the primary endpoint; on a network error or
 * a 5xx response retries once against the mirror. Throws a clear Error only if both
 * attempts fail. Returns only elements with a resolvable latlon.
 */
export async function fetchOsm(bbox: BBox): Promise<OsmFeature[]> {
  const query = buildOverpassQuery(bbox);

  let elements: OverpassElement[];
  try {
    elements = await postOverpass(OVERPASS_PRIMARY, query);
  } catch (primaryErr) {
    const e = primaryErr as Error & { retryable?: boolean };
    // Network errors have no `retryable` flag; HTTP 5xx sets it true. 4xx is fatal.
    const isNetwork = e.retryable === undefined;
    if (!isNetwork && e.retryable === false) {
      throw new Error(`Overpass request failed: ${e.message}`);
    }
    try {
      elements = await postOverpass(OVERPASS_MIRROR, query);
    } catch (mirrorErr) {
      const m = mirrorErr as Error;
      throw new Error(
        `Overpass request failed on both endpoints (${e.message}; mirror: ${m.message})`,
      );
    }
  }

  const features: OsmFeature[] = [];
  for (const el of elements) {
    const f = toFeature(el);
    if (f) features.push(f);
  }
  return features;
}
