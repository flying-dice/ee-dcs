import type { Terrain, TheatreFeature, BBox, LatLon, AirbasePoint, AirbaseFeatureCollection } from './types';

// ── DCS theatres, loaded from baked GeoJSON extractions ─────────────────────────
//
// Each theatre is a GeoJSON Feature under src/theatres/<Id>.geojson, produced by
// tools/dcs-export/theatre.lua run inside DCS (see that script's header). The Feature
// carries the real (warped) map-extent polygon and a proj4 string extracted from DCS
// itself — so projecting a lat/lon reproduces the game's own convertLatLonToMeters.
//
// To add a theatre: run the export script on that map in DCS, drop the resulting
// <Id>.geojson into src/theatres/, and rebuild. No code change needed.

// Vite bundles these as raw text (Vite doesn't parse .geojson natively) → JSON.parse.
// The folder holds two kinds of file: <Id>.geojson (the theatre Feature) and
// <Id>.airbases.geojson (a scraped airbase FeatureCollection).
const rawFiles = import.meta.glob('../theatres/*.geojson', {
  eager: true,
  query: '?raw',
  import: 'default',
}) as Record<string, string>;

// Airbase collections, keyed by terrain id (filename before ".airbases").
const airbasesByTerrain: Record<string, AirbasePoint[]> = {};
for (const [path, raw] of Object.entries(rawFiles)) {
  if (!path.endsWith('.airbases.geojson')) continue;
  const id = path.split('/').pop()!.replace('.airbases.geojson', '');
  const fc = JSON.parse(raw) as AirbaseFeatureCollection;
  airbasesByTerrain[id] = fc.features.map((f) => ({
    name: f.properties.name,
    category: f.properties.category,
    latlon: { lat: f.geometry.coordinates[1], lon: f.geometry.coordinates[0] },
  }));
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

function featureToTerrain(f: TheatreFeature): Terrain {
  const ring = ringToLatLon(f.geometry.coordinates[0]);
  const bounds = bboxOf(ring);
  const center: LatLon = { lat: f.properties.center.lat, lon: f.properties.center.lon };
  const anchors = f.properties.anchors ?? [];
  return {
    id: f.properties.id,
    label: f.properties.name || f.properties.id,
    center,
    airbases: airbasesByTerrain[f.properties.id] ?? [],
    boundsPolygon: ring,
    bounds,
    projString: f.properties.projection.proj,
    anchors,
    projectionValidated: anchors.length > 0,
    view: { center, zoom: zoomFor(bounds) },
  };
}

export const TERRAINS: Terrain[] = Object.entries(rawFiles)
  .filter(([path]) => !path.endsWith('.airbases.geojson'))
  .map(([, raw]) => featureToTerrain(JSON.parse(raw) as TheatreFeature))
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
