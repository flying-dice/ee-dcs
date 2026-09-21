import { bboxPolygon, featureCollection, intersect, multiPolygon, polygon } from '@turf/turf';
import type { MultiPolygon, Polygon } from 'geojson';
import type { AdminBoundary, BBox, Terrain } from './types';

/** Operational padding around the outermost DCS airfields. */
export const ACTIVE_AIRFIELD_BUFFER_KM = 100;

/** Build the usable theatre rectangle from the DCS airfield network. */
export function activeAreaBounds(
  terrain: Terrain,
  bufferKm = ACTIVE_AIRFIELD_BUFFER_KM,
): BBox {
  if (terrain.airbases.length === 0) return terrain.bounds;
  const lats = terrain.airbases.map((airbase) => airbase.latlon.lat);
  const lons = terrain.airbases.map((airbase) => airbase.latlon.lon);
  const centreLat = (Math.min(...lats) + Math.max(...lats)) / 2;
  const latPadding = bufferKm / 111.32;
  const lonPadding = bufferKm / (111.32 * Math.max(0.2, Math.cos(centreLat * Math.PI / 180)));
  return {
    north: Math.min(terrain.bounds.north, Math.max(...lats) + latPadding),
    south: Math.max(terrain.bounds.south, Math.min(...lats) - latPadding),
    east: Math.min(terrain.bounds.east, Math.max(...lons) + lonPadding),
    west: Math.max(terrain.bounds.west, Math.min(...lons) - lonPadding),
  };
}

function geometryBounds(boundary: AdminBoundary): BBox {
  let north = -Infinity;
  let south = Infinity;
  let east = -Infinity;
  let west = Infinity;
  const visit = (value: unknown): void => {
    if (!Array.isArray(value)) return;
    if (value.length >= 2 && typeof value[0] === 'number' && typeof value[1] === 'number') {
      west = Math.min(west, value[0]); east = Math.max(east, value[0]);
      south = Math.min(south, value[1]); north = Math.max(north, value[1]);
      return;
    }
    for (const child of value) visit(child);
  };
  visit(boundary.geometry.coordinates);
  return { north, south, east, west };
}

/** Clip selectable territory to the active airfield envelope, discarding DCS deadspace. */
export function clipAdminBoundaries(boundaries: AdminBoundary[], active: BBox): AdminBoundary[] {
  const clip = bboxPolygon([active.west, active.south, active.east, active.north]);
  return boundaries.flatMap((boundary): AdminBoundary[] => {
    const bounds = geometryBounds(boundary);
    if (bounds.east < active.west || bounds.west > active.east || bounds.north < active.south || bounds.south > active.north) return [];
    if (bounds.west >= active.west && bounds.east <= active.east && bounds.south >= active.south && bounds.north <= active.north) return [boundary];
    const source = boundary.geometry.type === 'Polygon'
      ? polygon(boundary.geometry.coordinates as number[][][])
      : multiPolygon(boundary.geometry.coordinates as number[][][][]);
    const clipped = intersect(featureCollection<Polygon | MultiPolygon>([source, clip]));
    if (!clipped) return [];
    return [{ ...boundary, geometry: clipped.geometry as AdminBoundary['geometry'] }];
  });
}
