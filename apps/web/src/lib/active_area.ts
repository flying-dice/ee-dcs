import type { BBox, Terrain } from './types';

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
