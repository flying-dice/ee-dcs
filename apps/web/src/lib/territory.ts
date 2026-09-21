import { cellArea, cellToBoundary, cellToLatLng, getResolution, isValidCell, latLngToCell } from 'h3-js';
import type {
  AssignedTerritory,
  BBox,
  LatLon,
  Side,
  Terrain,
  TerritoryAssignment,
  TerritoryPlan,
  TerritoryRole,
} from './types';

/** Territory painting and storage use one fixed H3 resolution. */
export const TERRITORY_RESOLUTION = 5;

function cellBounds(cell: string): BBox {
  const boundary = cellToBoundary(cell);
  const lats = boundary.map(([lat]) => lat);
  const lons = boundary.map(([, lon]) => lon);
  return {
    west: Math.min(...lons), east: Math.max(...lons),
    south: Math.min(...lats), north: Math.max(...lats),
  };
}

function insideTerrain(point: LatLon, ring: LatLon[]): boolean {
  let inside = false;
  for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index++) {
    const first = ring[index];
    const second = ring[previous];
    if ((first.lat > point.lat) !== (second.lat > point.lat) &&
      point.lon < ((second.lon - first.lon) * (point.lat - first.lat)) / (second.lat - first.lat) + first.lon) {
      inside = !inside;
    }
  }
  return inside;
}

/** Restrict paint strokes to resolution-5 cells inside the usable theatre. */
export function paintableCells(cell: string, terrain: Terrain, active: BBox): string[] {
  if (!isValidCell(cell) || getResolution(cell) !== TERRITORY_RESOLUTION) return [];
  const [lat, lon] = cellToLatLng(cell);
  return lon >= active.west && lon <= active.east && lat >= active.south && lat <= active.north &&
    insideTerrain({ lat, lon }, terrain.boundsPolygon) ? [cell] : [];
}

/** Prepare the explicit BLU/RED, Rear/Close cell assignments. */
export function buildTerritoryPlan(
  assignments: Readonly<Record<string, TerritoryAssignment>>,
): TerritoryPlan {
  const territories = Object.entries(assignments)
    .filter(([cell]) => isValidCell(cell) && getResolution(cell) === TERRITORY_RESOLUTION)
    .map(([cell, assignment]): AssignedTerritory => {
      const [lat, lon] = cellToLatLng(cell);
      return {
        id: cell,
        name: `H3 ${cell}`,
        owner: assignment.side,
        role: assignment.role,
        bounds: cellBounds(cell),
        areaKm2: cellArea(cell, 'km2'),
        representativePoint: { lat, lon },
      };
    })
    .sort((a, b) => a.id.localeCompare(b.id));

  const byCell = Object.fromEntries(territories.map((territory) => [territory.id, territory]));
  const bounds = territories.length === 0 ? null : territories.reduce<BBox>(
    (combined, territory) => ({
      west: Math.min(combined.west, territory.bounds.west),
      east: Math.max(combined.east, territory.bounds.east),
      south: Math.min(combined.south, territory.bounds.south),
      north: Math.max(combined.north, territory.bounds.north),
    }),
    { west: Infinity, east: -Infinity, south: Infinity, north: -Infinity },
  );

  return {
    territories,
    byCell,
    bounds,
    ownerCounts: {
      blue: territories.filter((territory) => territory.owner === 'blue').length,
      red: territories.filter((territory) => territory.owner === 'red').length,
    },
  };
}

export function territoryAt(plan: TerritoryPlan, location: LatLon): AssignedTerritory | undefined {
  if (!Number.isFinite(location.lat) || !Number.isFinite(location.lon)) return undefined;
  return plan.byCell[latLngToCell(location.lat, location.lon, TERRITORY_RESOLUTION)];
}

export function roleFor(plan: TerritoryPlan, location: LatLon): TerritoryRole | undefined {
  return territoryAt(plan, location)?.role;
}

export function countTerritories(plan: TerritoryPlan, side: Side, role: TerritoryRole): number {
  return plan.territories.filter((territory) => territory.owner === side && territory.role === role).length;
}
