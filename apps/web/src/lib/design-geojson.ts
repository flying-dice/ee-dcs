import { cellToBoundary, getResolution, isValidCell } from 'h3-js';
import { KEYSITE_TYPES } from './types';
import { TERRITORY_RESOLUTION } from './territory';
import { AIRCRAFT_ROLES } from './units';
import type { UnitTypes } from './units';
import type {
  AddedKeysite, CountConfig, DcsZone, Keysite, KeysiteType, LatLon,
  Side, TerritoryAssignment, TerritoryRole,
} from './types';

const FORMAT = 'ee-dcs-design';
const VERSION = 1;

export interface DesignState {
  terrainId: string;
  cellAssignments: Record<string, TerritoryAssignment>;
  mainBlueId: string | null;
  mainRedId: string | null;
  populated: boolean;
  counts: CountConfig;
  draftCounts: CountConfig;
  seed: number;
  removed: string[];
  added: AddedKeysite[];
  positionOverrides: Record<string, LatLon>;
  bakeCampaign: boolean;
  unitTypes: UnitTypes;
  assignmentSide: Side;
  assignmentRole: TerritoryRole;
  paintErase: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isSide(value: unknown): value is Side { return value === 'blue' || value === 'red'; }
function isRole(value: unknown): value is TerritoryRole { return value === 'rear' || value === 'close'; }
function isKeysiteType(value: unknown): value is KeysiteType {
  return KEYSITE_TYPES.some((type) => type === value);
}

function isLatLon(value: unknown): value is LatLon {
  return isRecord(value) && typeof value.lat === 'number' && Number.isFinite(value.lat) &&
    value.lat >= -90 && value.lat <= 90 && typeof value.lon === 'number' &&
    Number.isFinite(value.lon) && value.lon >= -180 && value.lon <= 180;
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.values(value).every((item) => typeof item === 'string');
}

function parseCounts(value: unknown): CountConfig | null {
  if (!isRecord(value)) return null;
  const entries: [KeysiteType, { blue: number; red: number }][] = [];
  for (const type of KEYSITE_TYPES) {
    const pair = value[type];
    if (!isRecord(pair) || !Number.isInteger(pair.blue) || !Number.isInteger(pair.red) ||
      typeof pair.blue !== 'number' || typeof pair.red !== 'number' ||
      pair.blue < 0 || pair.blue > 20 || pair.red < 0 || pair.red > 20) return null;
    entries.push([type, { blue: pair.blue, red: pair.red }]);
  }
  return Object.fromEntries(entries) as CountConfig;
}

function parseUnitTypes(value: unknown): UnitTypes | null {
  if (!isRecord(value) || !isRecord(value.blue) || !isRecord(value.red)) return null;
  const blue: Record<string, string> = {};
  const red: Record<string, string> = {};
  for (const { key } of AIRCRAFT_ROLES) {
    if (typeof value.blue[key] !== 'string' || typeof value.red[key] !== 'string') return null;
    blue[key] = value.blue[key];
    red[key] = value.red[key];
  }
  return { blue, red } as UnitTypes;
}

function isAddedKeysite(value: unknown): value is AddedKeysite {
  return isRecord(value) && typeof value.id === 'string' && value.id.length > 0 &&
    isKeysiteType(value.type) && isSide(value.side) && isLatLon(value.latlon) &&
    typeof value.name === 'string' &&
    (value.tags === undefined || isStringRecord(value.tags));
}

function isPolygon(value: unknown): boolean {
  if (!isRecord(value) || value.type !== 'Polygon' || !Array.isArray(value.coordinates) ||
    value.coordinates.length !== 1 || !Array.isArray(value.coordinates[0]) ||
    value.coordinates[0].length < 4) return false;
  const ring: unknown[] = value.coordinates[0];
  if (!ring.every((point) => Array.isArray(point) && point.length >= 2 &&
    typeof point[0] === 'number' && Number.isFinite(point[0]) && point[0] >= -180 && point[0] <= 180 &&
    typeof point[1] === 'number' && Number.isFinite(point[1]) && point[1] >= -90 && point[1] <= 90)) return false;
  const first = ring[0] as number[];
  const last = ring[ring.length - 1] as number[];
  return first[0] === last[0] && first[1] === last[1];
}

/** Spatial features are GIS-readable; their H3 IDs are authoritative on import. */
export function createDesignGeoJson(state: DesignState, keysites: Keysite[], zones: DcsZone[]) {
  const { cellAssignments, ...settings } = state;
  const territoryFeatures = Object.entries(cellAssignments).sort(([a], [b]) => a.localeCompare(b))
    .map(([cell, assignment]) => {
      const ring = cellToBoundary(cell).map(([lat, lon]) => [lon, lat]);
      ring.push([...ring[0]]);
      return {
        type: 'Feature' as const,
        properties: { kind: 'territory' as const, cell, ...assignment },
        geometry: { type: 'Polygon' as const, coordinates: [ring] },
      };
    });
  const siteFeatures = keysites.map((site, index) => ({
    type: 'Feature' as const,
    properties: {
      kind: 'keysite' as const, id: site.id, type: site.type, side: site.side,
      name: site.name, zone: zones[index],
    },
    geometry: { type: 'Point' as const, coordinates: [site.latlon.lon, site.latlon.lat] },
  }));
  return {
    type: 'FeatureCollection' as const,
    properties: { format: FORMAT, version: VERSION, terrain: state.terrainId,
      h3Resolution: TERRITORY_RESOLUTION, state: settings },
    features: [...territoryFeatures, ...siteFeatures],
  };
}

/** Reject bad or incompatible saves before the UI replaces any current state. */
export function parseDesignGeoJson(value: unknown): [DesignState, null] | [null, string] {
  if (!isRecord(value) || value.type !== 'FeatureCollection' || !Array.isArray(value.features) ||
    !isRecord(value.properties) || value.properties.format !== FORMAT) {
    return [null, 'This is not an EE-DCS design GeoJSON file.'];
  }
  const properties = value.properties;
  if (properties.version !== VERSION) return [null, 'This design file uses an unsupported version.'];
  if (properties.h3Resolution !== TERRITORY_RESOLUTION) {
    return [null, `This design uses a different H3 level; this editor requires level ${TERRITORY_RESOLUTION}.`];
  }
  if (typeof properties.terrain !== 'string' || !isRecord(properties.state)) {
    return [null, 'The design file has no valid theatre or settings.'];
  }
  const settings = properties.state;
  const assignments: Record<string, TerritoryAssignment> = {};
  for (const feature of value.features) {
    if (!isRecord(feature) || feature.type !== 'Feature' || !isRecord(feature.properties)) {
      return [null, 'The design contains a malformed GeoJSON feature.'];
    }
    if (feature.properties.kind === 'territory') {
      const { cell, side, role } = feature.properties;
      if (typeof cell !== 'string' || !isValidCell(cell) ||
        getResolution(cell) !== TERRITORY_RESOLUTION || !isSide(side) || !isRole(role) ||
        !isPolygon(feature.geometry) || Object.hasOwn(assignments, cell)) {
        return [null, 'The design contains an invalid or duplicate painted H3 cell.'];
      }
      assignments[cell] = { side, role };
    } else if (feature.properties.kind !== 'keysite') {
      return [null, 'The design contains an unknown feature type.'];
    } else if (!isRecord(feature.geometry) || feature.geometry.type !== 'Point' ||
      !Array.isArray(feature.geometry.coordinates) || feature.geometry.coordinates.length < 2 ||
      !isLatLon({ lon: feature.geometry.coordinates[0], lat: feature.geometry.coordinates[1] })) {
      return [null, 'The design contains an invalid keysite point.'];
    }
  }
  const counts = parseCounts(settings.counts);
  const draftCounts = parseCounts(settings.draftCounts);
  const unitTypes = parseUnitTypes(settings.unitTypes);
  if (!counts || !draftCounts || !unitTypes || typeof settings.populated !== 'boolean' ||
    !Number.isInteger(settings.seed) || typeof settings.seed !== 'number' ||
    !Array.isArray(settings.removed) || !settings.removed.every((id) => typeof id === 'string') ||
    !Array.isArray(settings.added) || !settings.added.every(isAddedKeysite) ||
    !isRecord(settings.positionOverrides) ||
    !Object.values(settings.positionOverrides).every(isLatLon) ||
    typeof settings.bakeCampaign !== 'boolean' || !isSide(settings.assignmentSide) ||
    !isRole(settings.assignmentRole) || typeof settings.paintErase !== 'boolean' ||
    !(settings.mainBlueId === null || typeof settings.mainBlueId === 'string') ||
    !(settings.mainRedId === null || typeof settings.mainRedId === 'string')) {
    return [null, 'The design file contains invalid generator settings.'];
  }
  return [{
    terrainId: properties.terrain,
    cellAssignments: assignments,
    mainBlueId: settings.mainBlueId,
    mainRedId: settings.mainRedId,
    populated: settings.populated,
    counts,
    draftCounts,
    seed: settings.seed,
    removed: settings.removed,
    added: settings.added,
    positionOverrides: settings.positionOverrides as Record<string, LatLon>,
    bakeCampaign: settings.bakeCampaign,
    unitTypes,
    assignmentSide: settings.assignmentSide,
    assignmentRole: settings.assignmentRole,
    paintErase: settings.paintErase,
  }, null];
}
