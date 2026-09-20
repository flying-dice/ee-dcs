// ── Keysite building: select + assign sides ─────────────────────────────────────
// The "game balancing" step, reworked around the designer flow:
//   terrain airbases (scraped from DCS) + drawn frontline + two designated main
//   airbases + per-type counts  →  buildKeysites()  →  Keysite[].
//
// Faithful to EECH's own campaign start (popread.c:557-1116): keysites are placed at
// their REAL feature locations and assigned to a side purely by the territory they sit
// in — get_initial_sector_side reads a painted red/blue map, so a keysite is BLUE/RED by
// whose ground it stands on, with NO front/rear/depth bias. Here the drawn frontline is
// that territory boundary. Airbase zones are REAL DCS airfields (each side's main forced);
// FARPs + support sites (factory/refinery/port/radar/power/command) are real OpenStreetMap
// features. The per-type count is the only cap EECH lacks: we take the most prominent real
// features per side, at their true positions. Seeded so Shuffle re-rolls which features
// are chosen; manual add/remove overrides survive shuffles.
//
// Pipeline position:  AirbasePoint[] + CandidateKeysite[] + BuildInput → Keysite[].

import type {
  CandidateKeysite,
  Keysite,
  KeysiteType,
  LatLon,
  Side,
  BBox,
  AirbasePoint,
  AddedKeysite,
  CountConfig,
} from './types';

// Default per-type targets (per side; edit in the panel). Shaped to an EECH warzone:
// basing-DOMINANT (airbases + FARPs), with the strategic/economic keysites SPARSE —
// EECH places each strategic site from a single KEY_ terrain marker (popread.c:1078-
// 1095), so a campaign has ~2 factories and ~1 of each other strategic type per side,
// not a dense industrial grid. ~12 per side total.
export const DEFAULT_COUNTS: CountConfig = {
  airbase: { blue: 2, red: 2 },   // fixed-wing is scarce in EECH — >2 tips into a fixed-wing war
  farp: { blue: 5, red: 5 },      // forward heli bases — the basing network is FARP-dominant
  factory: { blue: 2, red: 2 },   // FACTORY — industry-tied, the least-sparse strategic
  refinery: { blue: 1, red: 1 },  // OIL_REFINERY — single KEY_OIL marker
  port: { blue: 1, red: 1 },      // PORT — coastal only (0 inland)
  radar: { blue: 1, red: 1 },     // RADIO_TRANSMITTER — single KEY_RADIO marker
  power: { blue: 1, red: 1 },     // POWER_STATION — single KEY_POWER marker
  command: { blue: 1, red: 1 },   // MILITARY_BASE — single KEY_MILITARY marker
};

// Minimum spacing between two kept sites of the same type, metres (same-site dedup).
const MIN_SPACING_M = 4000;
// De-clutter radius across the WHOLE side network: a new keysite of ANY type is skipped
// if within this of one already placed, so the set spreads across the territory like a
// hand-authored map rather than stacking in one city. (Not an EECH rule — a curation
// proxy; EECH hand-picked sparse keysites, popread.c has no spacing logic.)
const DECLUTTER_M = 5000;
// FARPs are forward operating bases: generated behind the frontline in friendly
// territory, this far back (metres, seeded jitter between the two).
const FARP_MIN_OFFSET_M = 8000;
const FARP_MAX_OFFSET_M = 20000;

// Zone radii, metres — matches the port's sensible zone sizes.
const RADIUS_BY_TYPE: Record<KeysiteType, number> = {
  airbase: 2000,
  farp: 1200,
  factory: 1000,
  refinery: 1000,
  port: 1000,
  radar: 1000,
  power: 1000,
  command: 1000,
};

// Non-base types that come from OSM, alongside 'farp'.
const SUPPORT_TYPES: KeysiteType[] = [
  'factory', 'refinery', 'port', 'radar', 'power', 'command',
];
// All OSM-sourced types (farp first so it's filled before support sites).
const OSM_TYPES: KeysiteType[] = ['farp', ...SUPPORT_TYPES];

// ── geometry helpers ─────────────────────────────────────────────────────────────

// Great-circle distance in metres (haversine). Local copy so this module has no deps.
function distM(a: LatLon, b: LatLon): number {
  const R = 6371000;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLon = ((b.lon - a.lon) * Math.PI) / 180;
  const la1 = (a.lat * Math.PI) / 180;
  const la2 = (b.lat * Math.PI) / 180;
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(la1) * Math.cos(la2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function inBbox(p: LatLon, b: BBox): boolean {
  return p.lat >= b.south && p.lat <= b.north && p.lon >= b.west && p.lon <= b.east;
}

// Squared distance from point p to segment a→b, in lon/lat (x=lon, y=lat) space.
function distSqToSegment(p: LatLon, a: LatLon, b: LatLon): number {
  const abx = b.lon - a.lon;
  const aby = b.lat - a.lat;
  const apx = p.lon - a.lon;
  const apy = p.lat - a.lat;
  const len2 = abx * abx + aby * aby;
  const t = len2 > 0 ? Math.max(0, Math.min(1, (apx * abx + apy * aby) / len2)) : 0;
  const cx = a.lon + t * abx;
  const cy = a.lat + t * aby;
  const dx = p.lon - cx;
  const dy = p.lat - cy;
  return dx * dx + dy * dy;
}

/**
 * Which side of the drawn frontline a point lies on: +1 or -1. Finds the closest
 * polyline segment, then takes the sign of the 2D cross product. Pure — the UI calls
 * it to live-preview side colours and to classify airbases/candidates.
 */
export function sideOfFrontline(p: LatLon, frontline: LatLon[]): number {
  if (frontline.length < 2) return 1;
  let bestI = 0;
  let bestD = Infinity;
  for (let i = 0; i < frontline.length - 1; i++) {
    const d = distSqToSegment(p, frontline[i], frontline[i + 1]);
    if (d < bestD) {
      bestD = d;
      bestI = i;
    }
  }
  const a = frontline[bestI];
  const b = frontline[bestI + 1];
  const cross = (b.lon - a.lon) * (p.lat - a.lat) - (b.lat - a.lat) * (p.lon - a.lon);
  return cross >= 0 ? 1 : -1;
}

/** BLUE frontline sign, taken from the designated blue main (each side's main is the
 *  anchor for its half of the map). */
export function blueSignFrom(mainBlue: AirbasePoint | null, frontline: LatLon[]): number {
  return mainBlue ? sideOfFrontline(mainBlue.latlon, frontline) : 1;
}

// ── FARP placement: forward operating bases generated along the frontline ─────────
// FARPs aren't tied to real-world features — EECH scatters them as objects and the
// campaign spawns them at the zone. We place `count` of them evenly along the drawn
// frontline, offset into friendly territory, so they hug the front AND the requested
// count is always met (OSM rarely has that many real heli sites).

function frontlineLength(fl: LatLon[]): number {
  let c = 0;
  for (let i = 0; i < fl.length - 1; i++) c += distM(fl[i], fl[i + 1]);
  return c;
}

// Point at metre-distance `target` along the polyline, plus its segment index.
function pointAtAlong(fl: LatLon[], target: number): { lat: number; lon: number; i: number } {
  let cum = 0;
  for (let i = 0; i < fl.length - 1; i++) {
    const seg = distM(fl[i], fl[i + 1]);
    if (cum + seg >= target || i === fl.length - 2) {
      const t = seg > 0 ? Math.max(0, Math.min(1, (target - cum) / seg)) : 0;
      return {
        lat: fl[i].lat + t * (fl[i + 1].lat - fl[i].lat),
        lon: fl[i].lon + t * (fl[i + 1].lon - fl[i].lon),
        i,
      };
    }
    cum += seg;
  }
  return { lat: fl[0].lat, lon: fl[0].lon, i: 0 };
}

// (dLat, dLon) that moves `offsetM` metres perpendicular to the front into a side's turf.
function offsetIntoSide(
  fl: LatLon[],
  p: { lat: number; lon: number; i: number },
  side: Side,
  blueSign: number,
  offsetM: number,
): { dLat: number; dLon: number } {
  const a = fl[p.i];
  const b = fl[p.i + 1];
  const cosLat = Math.cos((p.lat * Math.PI) / 180) || 1e-6;
  const vx = (b.lon - a.lon) * cosLat * 111320;
  const vy = (b.lat - a.lat) * 111320;
  const len = Math.hypot(vx, vy) || 1;
  let nx = -vy / len;
  let ny = vx / len;
  // Flip the normal if it points at the enemy side.
  const wantSign = side === 'blue' ? blueSign : -blueSign;
  const testLat = p.lat + (ny * 1000) / 111320;
  const testLon = p.lon + (nx * 1000) / (cosLat * 111320);
  if (sideOfFrontline({ lat: testLat, lon: testLon }, fl) !== wantSign) {
    nx = -nx;
    ny = -ny;
  }
  return { dLat: (ny * offsetM) / 111320, dLon: (nx * offsetM) / (cosLat * 111320) };
}

function generateFarps(
  frontline: LatLon[],
  side: Side,
  blueSign: number,
  bbox: BBox,
  count: number,
  seed: number,
): { id: string; latlon: LatLon; name: string }[] {
  if (count <= 0 || frontline.length < 2) return [];
  const L = frontlineLength(frontline);
  const rnd = mulberry32(seed);
  const out: { id: string; latlon: LatLon; name: string }[] = [];
  for (let k = 0; k < count; k++) {
    // Even along the front, with a little seeded jitter so Shuffle re-rolls them.
    const frac = (k + 0.5) / count + (rnd() - 0.5) * (0.7 / count);
    const p = pointAtAlong(frontline, Math.max(0, Math.min(1, frac)) * L);
    const offsetM = FARP_MIN_OFFSET_M + rnd() * (FARP_MAX_OFFSET_M - FARP_MIN_OFFSET_M);
    const { dLat, dLon } = offsetIntoSide(frontline, p, side, blueSign, offsetM);
    const lat = Math.min(bbox.north, Math.max(bbox.south, p.lat + dLat));
    const lon = Math.min(bbox.east, Math.max(bbox.west, p.lon + dLon));
    out.push({ id: `farp:${side}:${k + 1}`, latlon: { lat, lon }, name: `${side}-${k + 1}` });
  }
  return out;
}

// ── seeded shuffle (so a Shuffle button re-rolls placements) ───────────────────────

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Small stable hash so each (type, side) shuffles independently from the same base seed.
function salt(type: KeysiteType, side: Side): number {
  const s = `${type}:${side}`;
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

// ── front/rear placement ─────────────────────────────────────────────────────────
// EECH placement model (popread.c:557-1116): keysites are placed at their REAL feature
// locations and assigned to a side purely by the territory they sit in (get_initial_
// sector_side reads a painted red/blue map — r>240 → RED, b>240 → BLUE). There is NO
// front/rear/depth bias of any kind: a factory is where the factory is, colored by whose
// ground it stands on. The web tool mirrors this — the drawn frontline IS the territory
// boundary, and every keysite keeps its real OSM/DCS position, colored by its side.
//
// The only non-EECH step is the per-type COUNT cap (EECH keeps every keysite the map
// author placed). We honour it faithfully: take the most prominent REAL features (OSM
// classification score) per type per side, deduping the same site by MIN_SPACING. A
// seeded jitter lets Shuffle re-roll among comparable features. No spatial shaping.
function pickNatural<T extends { latlon: LatLon }>(
  pool: T[],
  count: number,
  seed: number,
  seedKept: LatLon[],
  scoreOf?: (t: T) => number,
  spacing: number = MIN_SPACING_M,
): T[] {
  if (count <= 0 || pool.length === 0) return [];
  const rnd = mulberry32(seed);
  // Rank by feature prominence (score) with a light seeded jitter; equal-rank pools
  // (airfields carry no score) shuffle freely so a subset is chosen deterministically.
  const ranked = pool
    .map((item) => ({ item, key: scoreOf ? scoreOf(item) + rnd() * 25 : rnd() }))
    .sort((a, b) => b.key - a.key)
    .map((r) => r.item);
  // `seedKept` is the running set of everything already placed on this side, so the pick
  // de-clutters against the whole network (any type), not just its own kind.
  const kept: LatLon[] = [...seedKept];
  const out: T[] = [];
  for (const item of ranked) {
    if (out.length >= count) break;
    if (kept.every((k) => distM(k, item.latlon) >= spacing)) {
      kept.push(item.latlon);
      out.push(item);
    }
  }
  return out;
}

// ── identity + labelling ───────────────────────────────────────────────────────────

export function airbaseId(ab: AirbasePoint): string {
  return `ab:${ab.name}`;
}
export function candidateId(c: CandidateKeysite): string {
  return `osm:${c.source.id}`;
}

// Assign a unique-within-type label. Reuses the sanitised name; appends a numeric
// suffix on collision.
function labeller(): (type: KeysiteType, name: string) => string {
  const seen = new Map<string, number>();
  return (type, name) => {
    const base = (name || type).replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || type;
    const key = `${type}:${base}`;
    const n = (seen.get(key) ?? 0) + 1;
    seen.set(key, n);
    return n === 1 ? base : `${base}${n}`;
  };
}

// ── the builder ─────────────────────────────────────────────────────────────────

export interface BuildInput {
  bbox: BBox;
  frontline: LatLon[];
  /** All DCS airbases for the terrain (filtered to the bbox here). */
  airbases: AirbasePoint[];
  mainBlue: AirbasePoint | null;
  mainRed: AirbasePoint | null;
  /** Classified OSM sites (airbase-typed entries are ignored — airbases come from DCS). */
  osm: CandidateKeysite[];
  counts: CountConfig;
  /** Shuffle seed; bump it to re-roll placements. */
  seed: number;
  /** Ids the user explicitly removed — a hard blocklist, never re-added by a shuffle. */
  removed: string[];
  /** Sites the user explicitly added — always included, even beyond the counts. */
  added: AddedKeysite[];
}

/** True once both mains are set — the point at which candidates may be generated. */
export function canBuild(input: Pick<BuildInput, 'mainBlue' | 'mainRed' | 'frontline'>): boolean {
  return !!input.mainBlue && !!input.mainRed && input.frontline.length >= 2;
}

/**
 * Build the final keysite set. Airbases are DCS airfields split by the frontline with
 * each main force-included; FARPs + support sites are OSM candidates. Counts cap each
 * type per side; the seed re-rolls which sites are picked; removed/added overrides are
 * applied last and survive shuffles. Returns [] (with a console warning) if unbuildable.
 */
export function buildKeysites(input: BuildInput): Keysite[] {
  const { bbox, frontline, counts, seed } = input;
  if (!canBuild(input)) {
    console.warn('buildKeysites: need a frontline and both main airbases first');
    return [];
  }
  const blueSign = blueSignFrom(input.mainBlue, frontline);
  const removed = new Set(input.removed);
  const label = labeller();

  const sideOf = (p: LatLon): Side =>
    sideOfFrontline(p, frontline) === blueSign ? 'blue' : 'red';

  // Collect chosen candidates as {id,type,side,latlon,name,tags,isMain}, dedup by id.
  type Picked = {
    id: string;
    type: KeysiteType;
    side: Side;
    latlon: LatLon;
    name: string;
    tags?: Record<string, string>;
    isMain?: boolean;
  };
  const chosen = new Map<string, Picked>();
  // Running list of placed positions per side, so every pick de-clutters against the
  // whole side network (cross-type), spreading the set across the territory.
  const placedBySide: Record<Side, LatLon[]> = { blue: [], red: [] };
  const add = (p: Picked): void => {
    if (removed.has(p.id) || chosen.has(p.id)) return;
    chosen.set(p.id, p);
    placedBySide[p.side].push(p.latlon);
  };

  // ── airbases: DCS airfields, per side, mains forced ──────────────────────────────
  const abInBox = input.airbases.filter((a) => inBbox(a.latlon, bbox));
  const mains: Record<Side, AirbasePoint | null> = { blue: input.mainBlue, red: input.mainRed };

  for (const side of ['blue', 'red'] as Side[]) {
    const main = mains[side];
    let haveMain = 0;
    if (main && !removed.has(airbaseId(main))) {
      add({
        id: airbaseId(main),
        type: 'airbase',
        side,
        latlon: main.latlon,
        name: main.name,
        tags: { category: main.category, role: 'main' },
        isMain: true,
      });
      haveMain = 1;
    }
    // Extra airbases up to the per-side count (main already counts as one).
    const mainId = main ? airbaseId(main) : '';
    const pool = abInBox.filter((a) => sideOf(a.latlon) === side && airbaseId(a) !== mainId);
    const want = Math.max(0, (counts.airbase?.[side] ?? 0) - haveMain);
    // Extra airbases: a seeded subset of the side's real airfields, de-cluttered off the
    // main and each other (against the running side network).
    for (const a of pickNatural(pool, want, seed ^ salt('airbase', side), placedBySide[side], undefined, DECLUTTER_M)) {
      add({
        id: airbaseId(a),
        type: 'airbase',
        side,
        latlon: a.latlon,
        name: a.name,
        tags: { category: a.category },
      });
    }
  }

  // ── FARPs + support sites: OSM candidates, per type, per side ─────────────────────
  const osmInBox = input.osm.filter(
    (c) => c.type !== 'airbase' && inBbox(c.latlon, bbox),
  );
  for (const type of OSM_TYPES) {
    for (const side of ['blue', 'red'] as Side[]) {
      const want = counts[type]?.[side] ?? 0;
      if (want <= 0) continue;

      // FARPs: forward operating bases generated along the frontline (not from OSM), so
      // they hug the front and the exact requested count is always placed.
      if (type === 'farp') {
        for (const f of generateFarps(frontline, side, blueSign, bbox, want, seed ^ salt('farp', side))) {
          add({ id: f.id, type: 'farp', side, latlon: f.latlon, name: f.name });
        }
        continue;
      }

      const pool = osmInBox.filter((c) => c.type === type && sideOf(c.latlon) === side);
      const s = seed ^ salt(type, side);
      // EECH-faithful: most prominent real features of this type at their true locations
      // (no front/rear shaping), de-cluttered against the whole side network so the map
      // spreads out like a hand-authored theatre instead of stacking in one city.
      const picks = pickNatural(pool, want, s, placedBySide[side], (c) => c.score, DECLUTTER_M);
      for (const c of picks) {
        add({
          id: candidateId(c),
          type,
          side,
          latlon: c.latlon,
          name: c.name,
          tags: c.source.tags,
        });
      }
    }
  }

  // ── manual additions (forced, survive shuffles) ──────────────────────────────────
  for (const a of input.added) {
    if (removed.has(a.id)) continue;
    // A re-added airbase keeps its main flag if it matches a designated main.
    const isMain =
      (input.mainBlue && a.id === airbaseId(input.mainBlue)) ||
      (input.mainRed && a.id === airbaseId(input.mainRed)) ||
      undefined;
    add({
      id: a.id,
      type: a.type,
      side: a.side,
      latlon: a.latlon,
      name: a.name,
      tags: a.tags,
      isMain: isMain || undefined,
    });
  }

  // ── materialise Keysites with unique labels + radii ──────────────────────────────
  return [...chosen.values()].map((p) => ({
    id: p.id,
    type: p.type,
    side: p.side,
    latlon: p.latlon,
    label: label(p.type, p.name),
    radiusM: RADIUS_BY_TYPE[p.type],
    name: p.name,
    isMain: p.isMain,
    tags: p.tags,
  }));
}
