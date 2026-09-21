import { area, multiPolygon, pointOnFeature, polygon } from '@turf/turf';
import type {
  AdminBoundary,
  AssignedTerritory,
  BBox,
  LatLon,
  TerritoryAssignment,
  TerritoryPlan,
  TerritoryRole,
} from './types';

function geometryBounds(boundary: AdminBoundary): BBox {
  let west = Infinity;
  let east = -Infinity;
  let south = Infinity;
  let north = -Infinity;
  const visit = (value: unknown): void => {
    if (!Array.isArray(value)) return;
    if (value.length >= 2 && typeof value[0] === 'number' && typeof value[1] === 'number') {
      west = Math.min(west, value[0]);
      east = Math.max(east, value[0]);
      south = Math.min(south, value[1]);
      north = Math.max(north, value[1]);
      return;
    }
    for (const child of value) visit(child);
  };
  visit(boundary.geometry.coordinates);
  return { west, east, south, north };
}

function pointInRing(location: LatLon, ring: number[][]): boolean {
  let inside = false;
  for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index++) {
    const [x1, y1] = ring[index];
    const [x2, y2] = ring[previous];
    if (
      (y1 > location.lat) !== (y2 > location.lat) &&
      location.lon < ((x2 - x1) * (location.lat - y1)) / (y2 - y1) + x1
    ) inside = !inside;
  }
  return inside;
}

function polygonContains(location: LatLon, rings: number[][][]): boolean {
  return rings.length > 0 && pointInRing(location, rings[0]) &&
    rings.slice(1).every((hole) => !pointInRing(location, hole));
}

function boundaryContains(boundary: AdminBoundary, location: LatLon): boolean {
  return boundary.geometry.type === 'Polygon'
    ? polygonContains(location, boundary.geometry.coordinates as number[][][])
    : (boundary.geometry.coordinates as number[][][][]).some((part) =>
        polygonContains(location, part),
      );
}

/** Prepare the polygons selected and explicitly assigned by the mission author. */
export function buildTerritoryPlan(
  boundaries: AdminBoundary[],
  assignments: Readonly<Record<string, TerritoryAssignment>>,
): TerritoryPlan {
  const territories = boundaries
    .flatMap((boundary): AssignedTerritory[] => {
      const assignment = assignments[boundary.id];
      if (!assignment) return [];
      const feature = boundary.geometry.type === 'Polygon'
        ? polygon(boundary.geometry.coordinates as number[][][])
        : multiPolygon(boundary.geometry.coordinates as number[][][][]);
      const representative = pointOnFeature(feature).geometry.coordinates;
      return [{
        id: boundary.id,
        name: boundary.name,
        owner: assignment.side,
        role: assignment.role,
        boundary,
        bounds: geometryBounds(boundary),
        areaKm2: area(feature) / 1_000_000,
        representativePoint: { lon: representative[0], lat: representative[1] },
      }];
    })
    .sort((a, b) => a.id.localeCompare(b.id));

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
    bounds,
    ownerCounts: {
      blue: territories.filter((territory) => territory.owner === 'blue').length,
      red: territories.filter((territory) => territory.owner === 'red').length,
    },
  };
}

/** Find the assigned territory containing a point; overlaps prefer area, then id. */
export function territoryAt(plan: TerritoryPlan, location: LatLon): AssignedTerritory | undefined {
  return plan.territories
    .filter((territory) =>
      location.lon >= territory.bounds.west && location.lon <= territory.bounds.east &&
      location.lat >= territory.bounds.south && location.lat <= territory.bounds.north &&
      boundaryContains(territory.boundary, location),
    )
    .sort((a, b) => a.areaKm2 - b.areaKm2 || a.id.localeCompare(b.id))[0];
}

/** Return the author's explicit role for the territory containing a point. */
export function roleFor(plan: TerritoryPlan, location: LatLon): TerritoryRole | undefined {
  return territoryAt(plan, location)?.role;
}
