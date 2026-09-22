// ── slots.ts — bake human-flyable MP Client slots into the mission ────────────────
//
// Adds `4 Client slots per aircraft type at each compatible airbase`, as DCS
// "TakeOffParkingHot" (ramp, engines-on) groups placed on REAL parking spots. The unit
// table shape mirrors exactly what the Mission Editor writes for a Client aircraft
// (studied from a hand-placed example .miz): a group under
// coalition.<side>.country[n].{plane|helicopter}.group, whose route point starts
// "From Parking Area Hot" at the airfield's numeric airdromeId, and whose units carry
// skill="Client" on specific parking spots.
//
// HARD DATA DEPENDENCY: a ramp slot needs the airfield's numeric `airdromeId` plus real
// parking spots (Term_Index / Term_Type / world x,y). Those come only from a terrain
// exported with the current tools/dcs-export/airbases.lua. Airbases without parking data
// (older extractions) get NO slots — the caller surfaces the shortfall. Nothing is
// guessed: no synthetic airdromeId or parking id is ever emitted.
//
// "Compatible location":
//   • fixed-wing types  → AIRDROME airfields on that type's side
//   • helicopter types  → AIRDROME + HELIPAD airfields on that side
// FARPs are not eligible: they don't exist at mission load (the campaign spawns them at
// runtime), so there's no airdromeId to ramp-start from.

import type { Keysite, Terrain, AirbasePoint, ParkingSpot, Side } from './types';
import type { LuaObject, LuaValue } from './miz';
import type { AircraftRole, UnitTypes } from './units';
import { DEFAULT_UNIT_TYPES } from './units';

// Client slots per aircraft type per airfield.
const SLOTS_PER_TYPE = 4;
// ME default climb speed on the parking waypoint (m/s). Cosmetic for a ramp start.
const WP_SPEED = 138.88888888889;
// CJTF country ids that hold the blue/red coalitions (must match miz.ts roster).
const COUNTRY_ID: Record<Side, number> = { blue: 80, red: 81 };
const COUNTRY_NAME: Record<Side, string> = { blue: 'CJTF Blue', red: 'CJTF Red' };

type Category = 'plane' | 'helicopter';
type Size = 'fighter' | 'big' | 'heli';

// Each config role → its DCS object category + a size class used to match parking spots.
const ROLE_SPEC: Record<AircraftRole, { cat: Category; size: Size }> = {
  striker: { cat: 'plane', size: 'fighter' },
  escort: { cat: 'plane', size: 'fighter' },
  recon: { cat: 'plane', size: 'fighter' },
  transport_fw: { cat: 'plane', size: 'big' },
  transport_fw_heavy: { cat: 'plane', size: 'big' },
  attack_heli: { cat: 'helicopter', size: 'heli' },
  transport_heli: { cat: 'helicopter', size: 'heli' },
};

// DCS terminal-type codes (MOOSE AIRBASE.TerminalType): 16 runway, 40 helicopter-only,
// 68 shelter (fighter-size), 72 open-big, 104 open-med/big. A spot fits an airframe when
// its type is in the size's allow-set (never the runway itself).
function spotFits(size: Size, termType: number): boolean {
  switch (size) {
    case 'big':
      return termType === 72 || termType === 104;
    case 'fighter':
      return termType === 68 || termType === 72 || termType === 104;
    case 'heli':
      return termType === 40 || termType === 68 || termType === 72 || termType === 104;
  }
}

// A distinct aircraft type to base at compatible airfields (roles sharing a type collapse
// to one entry; the more restrictive size wins so a shared type still fits everywhere).
interface TypeSlot {
  type: string;
  cat: Category;
  size: Size;
}

export function distinctTypes(side: Side, units: UnitTypes[Side]): TypeSlot[] {
  const byType = new Map<string, TypeSlot>();
  for (const role of Object.keys(ROLE_SPEC) as AircraftRole[]) {
    const type = (units[role] ?? '').trim() || DEFAULT_UNIT_TYPES[side][role];
    if (!type) continue;
    const spec = ROLE_SPEC[role];
    const existing = byType.get(type);
    if (!existing) {
      byType.set(type, { type, cat: spec.cat, size: spec.size });
    } else if (spec.size === 'big' && existing.size === 'fighter') {
      existing.size = 'big'; // shared type must fit the most restrictive user
    }
  }
  // Allocate scarce spots first: big transports, then fighters, then flexible helis.
  const order: Size[] = ['big', 'fighter', 'heli'];
  return [...byType.values()].sort((a, b) => order.indexOf(a.size) - order.indexOf(b.size));
}

// A safe, unique-within-mission identifier fragment.
function slug(s: string): string {
  return s.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'x';
}

// Mutable id/name allocators so every baked group/unit is unique across the mission.
interface Ids {
  group: number;
  unit: number;
  onboard: number;
  names: Set<string>;
}

function uniqueName(ids: Ids, base: string): string {
  let name = base;
  let n = 2;
  while (ids.names.has(name)) name = `${base}-${n++}`;
  ids.names.add(name);
  return name;
}

// A generic numeric callsign preset ({[1],[2],[3],name}) DCS accepts for any airframe.
function callsign(name: string, indexInGroup: number): LuaObject {
  return { '[1]': 1, '[2]': indexInGroup, '[3]': 1, name };
}

// One Client unit on a specific parking spot.
function buildUnit(
  ids: Ids,
  type: string,
  groupName: string,
  indexInGroup: number,
  spot: ParkingSpot,
): LuaObject {
  const unitId = ids.unit++;
  const name = `${groupName}-${indexInGroup}`;
  const onboard = String(100 + (ids.onboard++ % 900)).padStart(3, '0');
  return {
    alt: spot.alt,
    alt_type: 'BARO',
    livery_id: 'default',
    skill: 'Client',
    parking: String(spot.termIndex),
    speed: WP_SPEED,
    type,
    unitId,
    psi: 0,
    onboard_num: onboard,
    parking_id: String(spot.termIndex),
    x: spot.x,
    name,
    payload: { pylons: {}, fuel: '99999', flare: 0, chaff: 0, gun: 100 },
    y: spot.y,
    heading: 0,
    callsign: callsign(name, indexInGroup),
  };
}

// One ramp-hot group of up to SLOTS_PER_TYPE Client units on the given spots.
function buildGroup(
  ids: Ids,
  ts: TypeSlot,
  ab: AirbasePoint,
  spots: ParkingSpot[],
): LuaObject {
  const groupId = ids.group++;
  const groupName = uniqueName(ids, `${slug(ts.type)}-${slug(ab.name)}`);
  const lead = spots[0];
  const units: LuaValue[] = spots.map((spot, i) => buildUnit(ids, ts.type, groupName, i + 1, spot));
  return {
    dynSpawnTemplate: false,
    modulation: 0,
    tasks: {},
    radioSet: false,
    task: 'Nothing',
    uncontrolled: false,
    route: {
      points: [
        {
          alt: lead.alt,
          action: 'From Parking Area Hot',
          alt_type: 'BARO',
          speed: WP_SPEED,
          task: { id: 'ComboTask', params: { tasks: {} } },
          type: 'TakeOffParkingHot',
          ETA: 0,
          ETA_locked: true,
          y: lead.y,
          x: lead.x,
          speed_locked: true,
          formation_template: '',
          airdromeId: ab.airdromeId as number,
        },
      ],
    },
    groupId,
    hidden: false,
    units,
    y: lead.y,
    x: lead.x,
    name: groupName,
    communication: true,
    start_time: 0,
    uncontrollable: false,
    frequency: ts.cat === 'helicopter' ? 127.5 : 305,
  };
}

/** Result of baking slots: the two country tables (or null) plus diagnostics. */
export interface SlotResult {
  /** coalition.blue.country[1] table, or null when the side has no bakeable slots. */
  blue: LuaObject | null;
  red: LuaObject | null;
  /** Total Client units baked across both sides. */
  slotCount: number;
  /** Human-readable notes: airfields with no parking data, or spots exhausted. */
  notes: string[];
}

/**
 * Build the per-side country tables holding Client MP slots. For every airbase keysite,
 * places SLOTS_PER_TYPE ramp-hot Client units of each compatible aircraft type on real,
 * non-reused parking spots. Airfields lacking exported parking data are skipped (noted).
 */
export function buildClientSlots(
  keysites: Keysite[],
  terrain: Terrain,
  unitTypes?: UnitTypes,
): SlotResult {
  const types: Record<Side, TypeSlot[]> = {
    blue: distinctTypes('blue', (unitTypes ?? DEFAULT_UNIT_TYPES).blue),
    red: distinctTypes('red', (unitTypes ?? DEFAULT_UNIT_TYPES).red),
  };
  const abByName = new Map(terrain.airbases.map((a) => [a.name, a]));
  const ids: Ids = { group: 1, unit: 1, onboard: 0, names: new Set() };
  const groups: Record<Side, { plane: LuaValue[]; helicopter: LuaValue[] }> = {
    blue: { plane: [], helicopter: [] },
    red: { plane: [], helicopter: [] },
  };
  const notes: string[] = [];
  let slotCount = 0;

  for (const ks of keysites) {
    if (ks.type !== 'airbase') continue;
    const ab = abByName.get(ks.name);
    if (!ab || ab.airdromeId === undefined || !ab.parking || ab.parking.length === 0) {
      notes.push(`${ks.name}: no parking data — re-export this terrain to base slots here`);
      continue;
    }
    const isHelipad = ab.category === 'HELIPAD';
    // Free take-off-capable spots at this airfield, consumed as we allocate.
    const free = ab.parking.filter((p) => p.toAc);
    const used = new Set<number>();

    for (const ts of types[ks.side]) {
      // Fixed-wing can't ramp-start from a helipad-only airfield.
      if (ts.cat === 'plane' && isHelipad) continue;
      const spots: ParkingSpot[] = [];
      for (const p of free) {
        if (spots.length >= SLOTS_PER_TYPE) break;
        if (used.has(p.termIndex)) continue;
        if (!spotFits(ts.size, p.termType)) continue;
        spots.push(p);
        used.add(p.termIndex);
      }
      if (spots.length === 0) {
        notes.push(`${ks.name}: no free ${ts.size} spot for ${ts.type}`);
        continue;
      }
      if (spots.length < SLOTS_PER_TYPE) {
        notes.push(`${ks.name}: only ${spots.length}/${SLOTS_PER_TYPE} ${ts.type} slots (spots exhausted)`);
      }
      groups[ks.side][ts.cat].push(buildGroup(ids, ts, ab, spots));
      slotCount += spots.length;
    }
  }

  const country = (side: Side): LuaObject | null => {
    const g = groups[side];
    if (g.plane.length === 0 && g.helicopter.length === 0) return null;
    const table: LuaObject = { id: COUNTRY_ID[side], name: COUNTRY_NAME[side] };
    if (g.plane.length > 0) table.plane = { group: g.plane };
    if (g.helicopter.length > 0) table.helicopter = { group: g.helicopter };
    return table;
  };

  return { blue: country('blue'), red: country('red'), slotCount, notes };
}
