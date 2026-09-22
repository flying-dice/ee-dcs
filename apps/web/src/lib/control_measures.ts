// ── Operational control-measure generation ─────────────────────────────────────
// User-placed objectives establish each side's axis of advance. Turf supplies the
// geodesic measurements used to derive maneuver-control lines and to score candidate
// keysites against the scenario's operational shape.

import {
  along,
  bearing,
  circle,
  destination,
  distance,
  length,
  lineIntersect,
  lineString,
  nearestPointOnLine,
  point,
} from '@turf/turf';
import type { BBox, KeysiteType, LatLon, ObjectiveFeature, OperationAxis, Side } from './types';

export type ControlMeasureKind =
  | 'axis'
  | 'assembly-area'
  | 'ld-lc'
  | 'phase-line'
  | 'flot'
  | 'limit-of-advance'
  | 'objective';

export interface ControlLine {
  geometry: 'line';
  kind: ControlMeasureKind;
  id: string;
  label: string;
  side: Side | 'both';
  points: LatLon[];
}

export interface ControlArea {
  geometry: 'area';
  kind: 'assembly-area';
  id: string;
  label: string;
  side: Side;
  ring: LatLon[];
}

export interface ControlPoint {
  geometry: 'point';
  kind: 'objective';
  id: string;
  label: string;
  side: 'both';
  point: LatLon;
  objectiveName: string;
  sourceId: string;
}

export type ControlMeasure = ControlLine | ControlArea | ControlPoint;

export interface OperationalAxis {
  objectiveId: string;
  objectiveName: string;
  points: [LatLon, LatLon];
  axisLengthKm: number;
  /** Friendly forward-support band, from the LD/LC to contact with the FLOT. */
  farpBand: { startKm: number; endKm: number };
}

export interface SideOperationalFramework {
  side: Side;
  axes: OperationalAxis[];
  supportAxis: { points: [LatLon, LatLon]; axisLengthKm: number };
  corridorWidthKm: number;
}

export interface ScenarioControlMeasures {
  measures: ControlMeasure[];
  sides: Partial<Record<Side, SideOperationalFramework>>;
}

export interface ControlMeasureInput {
  bbox: BBox;
  frontline: LatLon[];
  mainBlue: LatLon | null;
  mainRed: LatLon | null;
  objectives: ObjectiveFeature[];
  operationAxes?: OperationAxis[];
}

const toCoord = (p: LatLon): [number, number] => [p.lon, p.lat];
const fromCoord = (p: number[]): LatLon => ({ lon: p[0], lat: p[1] });
const clamp = (value: number, low: number, high: number): number =>
  Math.min(high, Math.max(low, value));

function crossLine(
  axis: ReturnType<typeof lineString>,
  atKm: number,
  widthKm: number,
): LatLon[] {
  const axisLength = length(axis, { units: 'kilometers' });
  const sample = clamp(Math.min(1, axisLength * 0.04), 0.1, 1);
  const before = along(axis, clamp(atKm - sample, 0, axisLength), { units: 'kilometers' });
  const after = along(axis, clamp(atKm + sample, 0, axisLength), { units: 'kilometers' });
  const heading = bearing(before, after);
  const center = along(axis, clamp(atKm, 0, axisLength), { units: 'kilometers' });
  const left = destination(center, widthKm / 2, heading - 90, { units: 'kilometers' });
  const right = destination(center, widthKm / 2, heading + 90, { units: 'kilometers' });
  return [fromCoord(left.geometry.coordinates), fromCoord(right.geometry.coordinates)];
}

function contactDistanceKm(
  axis: ReturnType<typeof lineString>,
  frontline: ReturnType<typeof lineString>,
  fallbackKm: number,
): number {
  const intersections = lineIntersect(axis, frontline);
  if (intersections.features.length === 0) {
    // Turf omits some endpoint contacts. Project the authored FLOT vertices onto the
    // axis and use the closest projection before falling back to a proportional depth.
    let closestDistanceKm = Infinity;
    let closestLocationKm = fallbackKm;
    for (const coordinates of frontline.geometry.coordinates) {
      const vertex = point(coordinates);
      const snapped = nearestPointOnLine(axis, vertex, { units: 'kilometers' });
      const separationKm = distance(vertex, snapped, { units: 'kilometers' });
      if (separationKm < closestDistanceKm) {
        closestDistanceKm = separationKm;
        closestLocationKm = snapped.properties.location ?? fallbackKm;
      }
    }
    return closestLocationKm;
  }
  let nearest = Infinity;
  for (const intersection of intersections.features) {
    const snapped = nearestPointOnLine(axis, intersection, { units: 'kilometers' });
    const location = snapped.properties.location;
    if (typeof location === 'number' && location < nearest) nearest = location;
  }
  return Number.isFinite(nearest) ? nearest : fallbackKm;
}

function buildSideFramework(
  side: Side,
  main: LatLon,
  operations: OperationAxis[],
  frontline: ReturnType<typeof lineString>,
  corridorWidthKm: number,
): { framework: SideOperationalFramework; measures: ControlMeasure[] } {
  const orderedOperations = [...operations].sort((a, b) =>
    bearing(point(toCoord(main)), point(toCoord(a.objective.latlon))) -
    bearing(point(toCoord(main)), point(toCoord(b.objective.latlon))),
  );
  const branches = orderedOperations.map((operation) => {
    const objective = operation.objective;
    const points: [LatLon, LatLon] = [operation.start, objective.latlon];
    const feature = lineString(points.map(toCoord));
    const axisLengthKm = length(feature, { units: 'kilometers' });
    const contactKm = contactDistanceKm(feature, frontline, axisLengthKm * 0.45);
    const ldKm = clamp(contactKm * 0.78, axisLengthKm * 0.12, axisLengthKm * 0.7);
    const heading = bearing(point(toCoord(operation.start)), point(toCoord(objective.latlon)));
    const loa = destination(point(toCoord(objective.latlon)), corridorWidthKm * 0.35, heading, {
      units: 'kilometers',
    });
    return {
      objective,
      feature,
      ldKm,
      ldPoint: fromCoord(along(feature, ldKm, { units: 'kilometers' }).geometry.coordinates),
      loaPoint: fromCoord(loa.geometry.coordinates),
      framework: {
        objectiveId: objective.id,
        objectiveName: objective.name,
        points,
        axisLengthKm,
        farpBand: {
          startKm: Math.min(ldKm, contactKm),
          endKm: Math.max(ldKm, contactKm),
        },
      } satisfies OperationalAxis,
    };
  });
  const prefix = side === 'blue' ? 'BLUE' : 'RED';
  const objectiveCenter: LatLon = {
    lat: orderedOperations.reduce((sum, operation) => sum + operation.objective.latlon.lat, 0) / orderedOperations.length,
    lon: orderedOperations.reduce((sum, operation) => sum + operation.objective.latlon.lon, 0) / orderedOperations.length,
  };
  const centerAxis = lineString([toCoord(main), toCoord(objectiveCenter)]);
  const assemblyKm = Math.min(...branches.map((branch) => branch.ldKm)) * 0.48;
  const assemblyCenter = along(centerAxis, assemblyKm, { units: 'kilometers' });
  const assembly = circle(assemblyCenter, corridorWidthKm * 0.22, {
    steps: 32,
    units: 'kilometers',
  });
  const frontageLine = (
    branchPoints: LatLon[],
    singleAxis: ReturnType<typeof lineString>,
    singleAtKm: number,
  ): LatLon[] => branchPoints.length > 1
    ? branchPoints
    : crossLine(singleAxis, singleAtKm, corridorWidthKm);

  const measures: ControlMeasure[] = [
    ...branches.map((branch): ControlLine => ({
      geometry: 'line',
      kind: 'axis',
      id: `${side}:axis:${branch.objective.id}`,
      label: `${prefix} AXIS · ${branch.objective.name}`,
      side,
      points: branch.framework.points,
    })),
    {
      geometry: 'area',
      kind: 'assembly-area',
      id: `${side}:aa`,
      label: `${prefix} AA`,
      side,
      ring: assembly.geometry.coordinates[0].map(fromCoord),
    },
    {
      geometry: 'line',
      kind: 'ld-lc',
      id: `${side}:ld-lc`,
      label: `${prefix} LD/LC`,
      side,
      points: frontageLine(
        branches.map((branch) => branch.ldPoint),
        branches[0].feature,
        branches[0].ldKm,
      ),
    },
    {
      geometry: 'line',
      kind: 'phase-line',
      id: `${side}:pl:objectives`,
      label: `${prefix} PL · OBJECTIVES`,
      side,
      points: frontageLine(
        branches.map((branch) => branch.objective.latlon),
        branches[0].feature,
        branches[0].framework.axisLengthKm,
      ),
    },
    {
      geometry: 'line',
      kind: 'limit-of-advance',
      id: `${side}:loa`,
      label: `${prefix} LOA`,
      side,
      points: frontageLine(
        branches.map((branch) => branch.loaPoint),
        lineString([toCoord(main), toCoord(branches[0].loaPoint)]),
        branches[0].framework.axisLengthKm + corridorWidthKm * 0.35,
      ),
    },
  ];

  return {
    framework: {
      side,
      axes: branches.map((branch) => branch.framework),
      supportAxis: {
        points: [main, objectiveCenter],
        axisLengthKm: length(centerAxis, { units: 'kilometers' }),
      },
      corridorWidthKm,
    },
    measures,
  };
}

export function generateControlMeasures(input: ControlMeasureInput): ScenarioControlMeasures {
  if (input.frontline.length < 2) return { measures: [], sides: {} };
  const diagonalKm = distance(
    point([input.bbox.west, input.bbox.south]),
    point([input.bbox.east, input.bbox.north]),
    { units: 'kilometers' },
  );
  const corridorWidthKm = clamp(diagonalKm * 0.12, 12, 40);
  const measures: ControlMeasure[] = [];
  const sides: Partial<Record<Side, SideOperationalFramework>> = {};
  if (input.frontline.length >= 2) {
    measures.push({
      geometry: 'line',
      kind: 'flot',
      id: 'both:flot',
      label: 'FLOT',
      side: 'both',
      points: input.frontline,
    });
  }
  measures.push(...input.objectives.map((objective): ControlPoint => ({
    geometry: 'point',
    kind: 'objective',
    id: `objective:${objective.id}`,
    label: `OBJ · ${objective.name}`,
    side: 'both',
    point: objective.latlon,
    objectiveName: objective.name,
    sourceId: objective.id,
  })));
  const frontlineFeature = lineString(input.frontline.map(toCoord));
  const mains: Record<Side, LatLon | null> = { blue: input.mainBlue, red: input.mainRed };
  for (const side of ['blue', 'red'] as Side[]) {
    const main = mains[side];
    if (!main || input.objectives.length === 0 || input.frontline.length < 2) continue;
    const operations = input.operationAxes?.length
      ? input.operationAxes.filter((operation) => {
          if (!input.mainBlue || !input.mainRed) return true;
          const fromBlue = distance(point(toCoord(operation.start)), point(toCoord(input.mainBlue)), { units: 'kilometers' });
          const fromRed = distance(point(toCoord(operation.start)), point(toCoord(input.mainRed)), { units: 'kilometers' });
          return side === (fromBlue <= fromRed ? 'blue' : 'red');
        })
      : input.objectives.map((objective) => ({
          id: `derived:${side}:${objective.id}`,
          start: main,
          objective,
        }));
    if (operations.length === 0) continue;
    const built = buildSideFramework(
      side,
      main,
      operations,
      frontlineFeature,
      corridorWidthKm,
    );
    sides[side] = built.framework;
    measures.push(...built.measures);
  }
  return { measures, sides };
}

const DESIRED_DEPTH: Record<Exclude<KeysiteType, 'farp'>, number> = {
  airbase: 0.12,
  command: 0.12,
  power: 0.18,
  refinery: 0.22,
  factory: 0.28,
  port: 0.3,
  radar: 0.42,
  depot: 0.2,
  fuel: 0.22,
};

/** Higher is better. Keeps infrastructure near the operational corridor while placing
 * command/sustainment in depth and sensors farther forward. */
export function operationalKeysiteWeight(
  framework: ScenarioControlMeasures,
  type: Exclude<KeysiteType, 'farp'>,
  side: Side,
  location: LatLon,
): number {
  const sideFramework = framework.sides[side];
  if (!sideFramework || sideFramework.axes.length === 0) return 0;
  const candidate = point(toCoord(location));
  const centralTypes = new Set<KeysiteType>([
    'airbase', 'command', 'factory', 'refinery', 'power', 'port', 'depot', 'fuel',
  ]);
  const scoringAxes = centralTypes.has(type)
    ? [sideFramework.supportAxis]
    : sideFramework.axes;
  return Math.max(...scoringAxes.map((branch) => {
    const axis = lineString(branch.points.map(toCoord));
    const nearest = nearestPointOnLine(axis, candidate, { units: 'kilometers' });
    const alongKm = nearest.properties.location ?? 0;
    const fraction = branch.axisLengthKm > 0 ? alongKm / branch.axisLengthKm : 0;
    const crossTrackKm = distance(candidate, nearest, { units: 'kilometers' });
    const corridorPenalty = crossTrackKm / Math.max(1, sideFramework.corridorWidthKm);
    const depthPenalty = Math.abs(fraction - DESIRED_DEPTH[type]);
    return 60 - corridorPenalty * 90 - depthPenalty * 60;
  }));
}

export function controlMeasureGeoJsonFeatures(framework: ScenarioControlMeasures): unknown[] {
  return framework.measures.map((measure) => {
    const properties: Record<string, string> = {
      kind: 'control-measure',
      measure: measure.kind,
      id: measure.id,
      label: measure.label,
      side: measure.side,
    };
    if (measure.geometry === 'point') {
      properties.objectiveName = measure.objectiveName;
      properties.sourceId = measure.sourceId;
      return { type: 'Feature', properties, geometry: { type: 'Point', coordinates: toCoord(measure.point) } };
    }
    if (measure.geometry === 'area') {
      return {
        type: 'Feature',
        properties,
        geometry: { type: 'Polygon', coordinates: [measure.ring.map(toCoord)] },
      };
    }
    return {
      type: 'Feature',
      properties,
      geometry: { type: 'LineString', coordinates: measure.points.map(toCoord) },
    };
  });
}
