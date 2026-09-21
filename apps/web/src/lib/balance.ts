// Territory-driven keysite selection and assignment.
import type { AddedKeysite, AirbasePoint, AssignedTerritory, CandidateKeysite, CountConfig, Keysite, KeysiteType, LatLon, Side, TerritoryPlan, TerritoryRole } from './types';
import { territoryAt } from './territory';

export const DEFAULT_COUNTS: CountConfig = {
  airbase: { blue: 2, red: 2 }, farp: { blue: 5, red: 5 },
  factory: { blue: 2, red: 2 }, refinery: { blue: 1, red: 1 },
  port: { blue: 1, red: 1 }, radar: { blue: 1, red: 1 },
  power: { blue: 1, red: 1 }, command: { blue: 1, red: 1 },
  depot: { blue: 1, red: 1 }, fuel: { blue: 1, red: 1 },
};

const MIN_SPACING_M = 4000;
const DECLUTTER_M = 5000;
const RADIUS_BY_TYPE: Record<KeysiteType, number> = {
  airbase: 2000, farp: 1200, factory: 1000, refinery: 1000,
  port: 1000, radar: 1000, power: 1000, command: 1000, depot: 1000, fuel: 1000,
};
type SupportType = Exclude<KeysiteType, 'airbase' | 'farp'>;
const OSM_TYPES: SupportType[] = ['factory', 'refinery', 'port', 'radar', 'power', 'command', 'depot', 'fuel'];

function distM(a: LatLon, b: LatLon): number {
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLon = ((b.lon - a.lon) * Math.PI) / 180;
  const latA = (a.lat * Math.PI) / 180;
  const latB = (b.lat * Math.PI) / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(latA) * Math.cos(latB) * Math.sin(dLon / 2) ** 2;
  return 12742000 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function salt(type: KeysiteType, side: Side): number {
  let hash = 2166136261;
  for (const character of `${type}:${side}`) {
    hash ^= character.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function requiredRole(type: Exclude<KeysiteType, 'airbase'>): TerritoryRole {
  return type === 'farp' || type === 'radar' ? 'close' : 'rear';
}

function validTerritoryFor(
  plan: TerritoryPlan,
  type: KeysiteType,
  side: Side,
  location: LatLon,
): boolean {
  const territory = territoryAt(plan, location);
  return territory?.owner === side &&
    (type === 'airbase' || territory.role === requiredRole(type));
}

function pickNatural<T extends { latlon: LatLon }>(
  pool: T[], count: number, seed: number, seedKept: LatLon[], scoreOf: (item: T) => number,
  spacing = MIN_SPACING_M,
): T[] {
  const random = mulberry32(seed);
  const ranked = pool.map((item, index) => ({ item, index, score: scoreOf(item) + random() * 25 }))
    .sort((a, b) => b.score - a.score || a.index - b.index).map(({ item }) => item);
  const kept = [...seedKept];
  const selected: T[] = [];
  for (const item of ranked) {
    if (selected.length >= count) break;
    if (kept.every((location) => distM(location, item.latlon) >= spacing)) {
      kept.push(item.latlon);
      selected.push(item);
    }
  }
  return selected;
}

function sampleTerritoryPoint(
  plan: TerritoryPlan,
  territory: AssignedTerritory,
  random: () => number,
  occupied: LatLon[],
  spacing: number,
): LatLon | undefined {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    const point = {
      lat: territory.bounds.south + random() * (territory.bounds.north - territory.bounds.south),
      lon: territory.bounds.west + random() * (territory.bounds.east - territory.bounds.west),
    };
    if (territoryAt(plan, point)?.id === territory.id && occupied.every((other) => distM(point, other) >= spacing)) return point;
  }
  return undefined;
}

function generateFarps(
  plan: TerritoryPlan, side: Side, count: number, seed: number, alreadyPlaced: LatLon[],
): { id: string; latlon: LatLon; name: string }[] {
  const territories = plan.territories
    .filter((territory) => territory.owner === side && territory.role === 'close')
    .sort((a, b) => a.id.localeCompare(b.id));
  if (territories.length === 0) return [];
  const random = mulberry32(seed);
  const offset = Math.floor(random() * territories.length);
  const occupied = [...alreadyPlaced];
  const farps: { id: string; latlon: LatLon; name: string }[] = [];
  for (let index = 0; index < count; index += 1) {
    let point: LatLon | undefined;
    let territory: AssignedTerritory | undefined;
    for (const spacing of [MIN_SPACING_M, 2000, 500]) {
      for (let step = 0; step < territories.length; step += 1) {
        const candidate = territories[(offset + index + step) % territories.length];
        point = sampleTerritoryPoint(plan, candidate, random, occupied, spacing);
        if (point) { territory = candidate; break; }
      }
      if (point) break;
    }
    if (!point || !territory) continue;
    occupied.push(point);
    farps.push({ id: `farp:${side}:${index + 1}`, latlon: point, name: `${territory.name || side} ${index + 1}` });
  }
  return farps;
}

export function airbaseId(airbase: AirbasePoint): string { return `ab:${airbase.name}`; }
export function candidateId(candidate: CandidateKeysite): string { return `osm:${candidate.source.id}`; }

function labeller(): (type: KeysiteType, name: string) => string {
  const seen = new Map<string, number>();
  return (type, name) => {
    const base = (name || type).replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || type;
    const key = `${type}:${base}`;
    const occurrence = (seen.get(key) ?? 0) + 1;
    seen.set(key, occurrence);
    return occurrence === 1 ? base : `${base}${occurrence}`;
  };
}

export interface BuildInput {
  territoryPlan: TerritoryPlan;
  airbases: AirbasePoint[];
  mainBlue: AirbasePoint | null;
  mainRed: AirbasePoint | null;
  osm: CandidateKeysite[];
  counts: CountConfig;
  seed: number;
  removed: string[];
  added: AddedKeysite[];
  positionOverrides: Record<string, LatLon>;
}

export function canBuild(input: Pick<BuildInput, 'mainBlue' | 'mainRed' | 'territoryPlan'>): boolean {
  return !!input.mainBlue && !!input.mainRed &&
    input.territoryPlan.ownerCounts.blue > 0 && input.territoryPlan.ownerCounts.red > 0 &&
    territoryAt(input.territoryPlan, input.mainBlue.latlon)?.owner === 'blue' &&
    territoryAt(input.territoryPlan, input.mainRed.latlon)?.owner === 'red';
}

export function buildKeysites(input: BuildInput): Keysite[] {
  if (!canBuild(input)) {
    console.warn('buildKeysites: each side needs assigned territory containing its main airbase');
    return [];
  }
  const { territoryPlan: plan, counts, seed } = input;
  const removed = new Set(input.removed);
  const label = labeller();
  type Picked = { id: string; type: KeysiteType; side: Side; latlon: LatLon; name: string; tags?: Record<string, string>; isMain?: boolean; locationTied: boolean };
  const chosen = new Map<string, Picked>();
  const placedBySide: Record<Side, LatLon[]> = { blue: [], red: [] };
  const add = (picked: Picked, force = false): void => {
    if ((!force && removed.has(picked.id)) || chosen.has(picked.id)) return;
    chosen.set(picked.id, picked);
    placedBySide[picked.side].push(picked.latlon);
  };

  const mains: Record<Side, AirbasePoint | null> = { blue: input.mainBlue, red: input.mainRed };
  const mainIds = new Set(Object.values(mains).filter((main): main is AirbasePoint => main !== null).map(airbaseId));
  for (const side of ['blue', 'red'] as Side[]) {
    const main = mains[side];
    let haveMain = 0;
    if (main) {
      add({ id: airbaseId(main), type: 'airbase', side, latlon: main.latlon, name: main.name,
        tags: { category: main.category, role: 'main' }, isMain: true, locationTied: true }, true);
      haveMain = 1;
    }
    const pool = input.airbases.filter((airbase) => !mainIds.has(airbaseId(airbase)) &&
      !removed.has(airbaseId(airbase)) && territoryAt(plan, airbase.latlon)?.owner === side);
    for (const airbase of pickNatural(pool, Math.max(0, (counts.airbase?.[side] ?? 0) - haveMain),
      seed ^ salt('airbase', side), placedBySide[side], () => 0, DECLUTTER_M)) {
      add({ id: airbaseId(airbase), type: 'airbase', side, latlon: airbase.latlon,
        name: airbase.name, tags: { category: airbase.category }, locationTied: true });
    }
  }

  const osmInTerritory = input.osm.filter((candidate) => candidate.type !== 'airbase' && territoryAt(plan, candidate.latlon));
  for (const side of ['blue', 'red'] as Side[]) {
    const want = counts.farp?.[side] ?? 0;
    const blocked = input.removed.filter((id) => id.startsWith(`farp:${side}:`)).length;
    let placed = 0;
    for (const farp of generateFarps(plan, side, want + blocked, seed ^ salt('farp', side), placedBySide[side])) {
      if (removed.has(farp.id)) continue;
      add({ ...farp, type: 'farp', side, locationTied: false });
      if (++placed === want) break;
    }
  }
  for (const type of OSM_TYPES) {
    for (const side of ['blue', 'red'] as Side[]) {
      const want = counts[type]?.[side] ?? 0;
      if (want <= 0) continue;
      const pool = osmInTerritory.filter((candidate) => {
        const territory = territoryAt(plan, candidate.latlon);
        return candidate.type === type && territory?.owner === side &&
          territory.role === requiredRole(type) && !removed.has(candidateId(candidate));
      });
      for (const candidate of pickNatural(pool, want, seed ^ salt(type, side), placedBySide[side],
        (item) => item.score, DECLUTTER_M)) {
        add({ id: candidateId(candidate), type, side, latlon: candidate.latlon,
          name: candidate.name, tags: candidate.source.tags, locationTied: true });
      }
    }
  }

  for (const addition of input.added) {
    if (removed.has(addition.id) || mainIds.has(addition.id)) continue;
    const territory = territoryAt(plan, addition.latlon);
    if (territory && validTerritoryFor(plan, addition.type, territory.owner, addition.latlon)) {
      add({ ...addition, side: territory.owner, locationTied: true });
    }
  }

  return [...chosen.values()].map((picked) => {
    const override = input.positionOverrides[picked.id];
    const latlon = override && validTerritoryFor(plan, picked.type, picked.side, override)
      ? override
      : picked.latlon;
    return { ...picked, latlon, label: label(picked.type, picked.name), radiusM: RADIUS_BY_TYPE[picked.type] };
  });
}
