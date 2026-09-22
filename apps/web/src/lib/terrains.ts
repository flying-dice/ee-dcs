import type {
  Terrain,
  TheatreFeature,
  BBox,
  LatLon,
  AirbasePoint,
  AirbaseFeatureCollection,
  ParkingSpot,
} from './types';

// ── DCS theatres, loaded from baked GeoJSON extractions ─────────────────────────
//
// Each theatre is ONE GeoJSON file under src/theatres/<Id>.geojson. It is either a bare
// TERRAIN Feature (the map-extent polygon + a proj4 string extracted from DCS, so
// projecting a lat/lon reproduces the game's own convertLatLonToMeters) or — once the
// airbase export has run — a FeatureCollection holding that TERRAIN feature plus one
// AIRBASE point per airfield and one PARKING point per spot (see tools/dcs-export).
//
// To add a theatre: run tools/dcs-export/theatre.lua for the TERRAIN feature, then
// tools/dcs-export/theatre-dump.lua to fold airbases+parking into the same file. Drop it
// into src/theatres/ and rebuild — the app globs this folder, no code change needed.

// Vite bundles these as raw text (Vite doesn't parse .geojson natively) → JSON.parse.
const rawFiles = import.meta.glob('../theatres/*.geojson', {
  eager: true,
  query: '?raw',
  import: 'default',
}) as Record<string, string>;

// Build airfields from the AIRBASE/PARKING features, joining each parking spot to its
// airfield by numeric airdromeId (present only once a terrain has the current export).
function parseAirbaseFeatures(features: AirbaseFeatureCollection['features']): AirbasePoint[] {
  const airbases: AirbasePoint[] = [];
  const byAirdromeId = new Map<number, AirbasePoint>();
  const parkingByAirdromeId = new Map<number, ParkingSpot[]>();

  for (const f of features) {
    const p = f.properties;
    if (p.type === 'TERRAIN') continue; // the map-extent feature, handled separately
    if (p.type === 'PARKING') {
      // DCS world metres: export x = north (unit x), z = east (unit y).
      if (p.airdromeId === undefined || p.Term_Index === undefined) continue;
      const list = parkingByAirdromeId.get(p.airdromeId) ?? [];
      list.push({
        termIndex: p.Term_Index,
        termType: p.Term_Type ?? 0,
        toAc: p.TO_AC ?? false,
        x: p.x ?? 0,
        y: p.z ?? 0,
        alt: f.geometry.coordinates[2] ?? 0,
      });
      parkingByAirdromeId.set(p.airdromeId, list);
      continue;
    }
    // AIRBASE (or legacy features with no explicit type but a name/category).
    const ab: AirbasePoint = {
      name: p.name ?? '',
      category: p.category ?? '',
      latlon: { lat: f.geometry.coordinates[1], lon: f.geometry.coordinates[0] },
      airdromeId: p.airdromeId,
      dcs: p.x !== undefined && p.z !== undefined ? { x: p.x, y: p.z } : undefined,
    };
    airbases.push(ab);
    if (p.airdromeId !== undefined) byAirdromeId.set(p.airdromeId, ab);
  }

  // Attach parking to its airfield (only when the export carried airdromeId + spots).
  for (const [aid, spots] of parkingByAirdromeId) {
    const ab = byAirdromeId.get(aid);
    if (ab) ab.parking = spots;
  }
  return airbases;
}

// Split one theatre file into its TERRAIN feature (projection/bounds) + parsed airbases.
// Accepts a bare TERRAIN Feature or a FeatureCollection carrying it. Null if no TERRAIN.
function splitTheatreFile(raw: string): { terrain: TheatreFeature; airbases: AirbasePoint[] } | null {
  const data = JSON.parse(raw) as
    | TheatreFeature
    | { type: 'FeatureCollection'; features: AirbaseFeatureCollection['features'] };
  if (data.type === 'Feature') {
    return { terrain: data, airbases: [] };
  }
  if (data.type === 'FeatureCollection') {
    const terrain = data.features.find((f) => f.properties?.type === 'TERRAIN') as unknown as
      | TheatreFeature
      | undefined;
    if (!terrain) return null;
    return { terrain, airbases: parseAirbaseFeatures(data.features) };
  }
  return null;
}

function ringToLatLon(ring: number[][]): LatLon[] {
  return ring.map(([lon, lat]) => ({ lat, lon }));
}

function bboxOf(ring: LatLon[]): BBox {
  const lats = ring.map((p) => p.lat);
  const lons = ring.map((p) => p.lon);
  return {
    north: Math.max(...lats),
    south: Math.min(...lats),
    east: Math.max(...lons),
    west: Math.min(...lons),
  };
}

/** Pick an initial Leaflet zoom that frames the whole map extent. */
function zoomFor(bounds: BBox): number {
  const span = Math.max(bounds.north - bounds.south, bounds.east - bounds.west);
  if (span > 18) return 5;
  if (span > 10) return 6;
  if (span > 5) return 7;
  return 8;
}

function featureToTerrain(f: TheatreFeature, airbases: AirbasePoint[]): Terrain {
  const ring = ringToLatLon(f.geometry.coordinates[0]);
  const bounds = bboxOf(ring);
  const center: LatLon = { lat: f.properties.center.lat, lon: f.properties.center.lon };
  const anchors = f.properties.anchors ?? [];
  return {
    id: f.properties.id,
    label: f.properties.name || f.properties.id,
    center,
    airbases,
    boundsPolygon: ring,
    bounds,
    projString: f.properties.projection.proj,
    anchors,
    projectionValidated: anchors.length > 0,
    view: { center, zoom: zoomFor(bounds) },
  };
}

export const TERRAINS: Terrain[] = Object.values(rawFiles)
  .map((raw) => splitTheatreFile(raw))
  .filter((s): s is { terrain: TheatreFeature; airbases: AirbasePoint[] } => s !== null)
  .map(({ terrain, airbases }) => featureToTerrain(terrain, airbases))
  .sort((a, b) => a.label.localeCompare(b.label));

export function terrainById(id: string): Terrain | undefined {
  return TERRAINS.find((t) => t.id === id);
}

// ── Geometry helpers used by the UI for containment validation ──────────────────

/** Ray-casting point-in-polygon against a lon/lat ring. */
export function pointInPolygon(p: LatLon, ring: LatLon[]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i].lon, yi = ring[i].lat;
    const xj = ring[j].lon, yj = ring[j].lat;
    const intersect =
      (yi > p.lat) !== (yj > p.lat) &&
      p.lon < ((xj - xi) * (p.lat - yi)) / (yj - yi) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

/** True iff every corner of the bbox sits inside the terrain's playable polygon. */
export function bboxInsideTerrain(b: BBox, terrain: Terrain): boolean {
  const corners: LatLon[] = [
    { lat: b.north, lon: b.west },
    { lat: b.north, lon: b.east },
    { lat: b.south, lon: b.east },
    { lat: b.south, lon: b.west },
  ];
  return corners.every((c) => pointInPolygon(c, terrain.boundsPolygon));
}
