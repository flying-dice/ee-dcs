// ── OSM feature → candidate keysite classifier ─────────────────────────────────
// Maps each raw OSM feature onto one of the eight EECH land keysite types (ks_dbase.c
// sub-types, mirrored in the port's zones.lua). First matching rule wins; the tag
// each rule keys on is cited inline. Produces the full CandidateKeysite list —
// balance.ts does the trimming and side assignment.
//
// Fuel/oil storage → `refinery` (EECH OIL_REFINERY — fuel logistics) and military
// depots/ammunition → `command` (EECH MILITARY_BASE): EECH has no separate DEPOT or
// FUEL keysite, so those OSM features fold onto the real rows they belong to.
//
// Pipeline position:  OsmFeature[] → classifyFeatures() → CandidateKeysite[] → balance.ts.

import type { OsmFeature, CandidateKeysite, KeysiteType } from './types';

// Near-duplicate collapse radius: two candidates of the same type closer than this
// are the same real-world site (an area often carries both a node and a way).
const DEDUP_RADIUS_M = 300;

// Great-circle distance in metres (haversine). Local copy so this module has no deps.
function distM(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const R = 6371000;
  const dLat = ((bLat - aLat) * Math.PI) / 180;
  const dLon = ((bLon - aLon) * Math.PI) / 180;
  const la1 = (aLat * Math.PI) / 180;
  const la2 = (bLat * Math.PI) / 180;
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(la1) * Math.cos(la2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

// Sanitise a label down to [a-z0-9] (matches the port's first-word/label parsing).
function sanitise(raw: string | undefined): string {
  if (!raw) return '';
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '')
    .slice(0, 24);
}

// True when the feature is an area (way/relation) rather than a point node — our
// proxy for "large", used to reject tiny amenity=fuel petrol stations etc.
function isArea(f: OsmFeature): boolean {
  return f.id.startsWith('way/') || f.id.startsWith('relation/');
}

// Result of classifying one feature (before naming / dedup).
interface Classification {
  type: KeysiteType;
  score: number;
}

// Apply the tag rules to a single feature. First match wins. More-specific rules
// come before broad catch-alls (petroleum_refinery before generic works→factory;
// landuse=industrial factory last).
function classifyOne(f: OsmFeature): Classification | null {
  const t = f.tags;
  const area = isArea(f);

  // ── airbase / farp (aeroway) ───────────────────────────────────────────────
  if (t.aeroway === 'aerodrome') {
    // Real airport: international/regional class, or has an ICAO/IATA code → airbase.
    if (
      t['aerodrome:type'] === 'international' ||
      t['aerodrome:type'] === 'regional' ||
      t.icao ||
      t.iata
    ) {
      return { type: 'airbase', score: 100 };
    }
    // Unclassified aerodrome (small airfield, no code) → forward heli base candidate.
    return { type: 'farp', score: 60 };
  }
  if (t.aeroway === 'heliport') return { type: 'farp', score: 55 }; // aeroway=heliport → farp
  if (t.military === 'airfield') return { type: 'farp', score: 58 }; // military airstrip → farp

  // ── refinery (before factory: man_made=works can be either) ────────────────
  if (t.man_made === 'petroleum_refinery') return { type: 'refinery', score: 88 };
  if (t.industrial === 'oil' || t.industrial === 'refinery') return { type: 'refinery', score: 86 };
  if (t.man_made === 'works' && /oil|petro|fuel/i.test(t.product ?? '')) {
    return { type: 'refinery', score: 84 }; // works producing oil/petroleum
  }

  // ── radar ───────────────────────────────────────────────────────────────────
  if (t.man_made === 'radar') return { type: 'radar', score: 74 };
  if (t.military === 'radar_station') return { type: 'radar', score: 76 };
  if (t['tower:type'] === 'radar') return { type: 'radar', score: 70 };

  // ── power ─────────────────────────────────────────────────────────────────
  if (t.power === 'plant' || t.man_made === 'power_station') return { type: 'power', score: 80 };
  // substation: only the larger (mapped-as-area) ones — skip pole-top nodes.
  if (t.power === 'substation' && area) return { type: 'power', score: 48 };

  // ── port ─────────────────────────────────────────────────────────────────
  if (t.harbour === 'yes' || t.landuse === 'harbour' || t.industrial === 'port') {
    return { type: 'port', score: 76 };
  }
  if (t.amenity === 'ferry_terminal') return { type: 'port', score: 70 };
  if (t.man_made === 'pier' && area) return { type: 'port', score: 55 }; // major (area) pier

  // ── fuel/oil storage → refinery (EECH OIL_REFINERY — fuel logistics) ────────
  if (t.man_made === 'storage_tank' || t.man_made === 'tank_farm') {
    return { type: 'refinery', score: 62 }; // fuel/oil storage → OIL_REFINERY
  }
  if (t.landuse === 'depot' && /fuel|oil|petro/i.test(t.substance ?? t.resource ?? '')) {
    return { type: 'refinery', score: 60 }; // fuel depot → OIL_REFINERY
  }
  if (t.amenity === 'fuel' && area) return { type: 'refinery', score: 45 }; // large fuel depot only

  // ── military depot / ammunition → command (EECH MILITARY_BASE) ──────────────
  if (t.military === 'depot' || t.military === 'ammunition') return { type: 'command', score: 66 };
  if (t.landuse === 'depot') return { type: 'command', score: 58 };

  // ── command (MILITARY_BASE) ─────────────────────────────────────────────────
  if (t.military === 'bunker') return { type: 'command', score: 56 };
  if (t.military === 'barracks') return { type: 'command', score: 54 };
  if (t.office === 'government') return { type: 'command', score: 50 };

  // ── factory (broad industrial catch-all, last) ────────────────────────────
  if (t.man_made === 'works') return { type: 'factory', score: 70 };
  if (t.building === 'industrial') return { type: 'factory', score: 52 };
  if (t.landuse === 'industrial' && area) return { type: 'factory', score: 50 }; // large industrial area

  return null; // no rule matched — not a keysite
}

/**
 * Classify OSM features into candidate keysites. Resilient to messy/missing tags:
 * unmatched features are dropped, names fall back to `<type><index>`, and near-
 * duplicate points of the same type collapse to the highest-scoring one.
 */
export function classifyFeatures(features: OsmFeature[]): CandidateKeysite[] {
  const raw: CandidateKeysite[] = [];
  const typeCounts: Partial<Record<KeysiteType, number>> = {};

  for (const f of features) {
    const c = classifyOne(f);
    if (!c) continue;
    const idx = (typeCounts[c.type] ?? 0) + 1;
    typeCounts[c.type] = idx;
    const name = sanitise(f.name) || `${c.type}${idx}`;
    raw.push({ type: c.type, latlon: f.latlon, name, score: c.score, source: f });
  }

  // Dedup: process highest score first; keep a candidate only if no already-kept
  // candidate of the same type sits within DEDUP_RADIUS_M. Deterministic tiebreak
  // on source id keeps the output stable for identical input.
  raw.sort((a, b) => b.score - a.score || a.source.id.localeCompare(b.source.id));

  const kept: CandidateKeysite[] = [];
  for (const cand of raw) {
    const dup = kept.some(
      (k) =>
        k.type === cand.type &&
        distM(k.latlon.lat, k.latlon.lon, cand.latlon.lat, cand.latlon.lon) < DEDUP_RADIUS_M,
    );
    if (!dup) kept.push(cand);
  }
  return kept;
}
