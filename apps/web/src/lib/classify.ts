// ── OSM feature → candidate keysite classifier ─────────────────────────────────
// Maps each raw OSM feature onto one of the campaign's authored keysite types (ks_dbase.c
// sub-types, mirrored in the port's zones.lua). First matching rule wins; the tag
// each rule keys on is cited inline. Produces the full CandidateKeysite list —
// balance.ts does the trimming and side assignment.
//
// Start with named, explicitly mapped facilities. Small components such as
// piers, storage tanks and substations do not represent campaign keysites.
//
// Pipeline position:  OsmFeature[] → classifyFeatures() → CandidateKeysite[] → balance.ts.

import { classifyOsmSite } from './osm-policy.mjs';
import type { OsmFeature, CandidateKeysite, KeysiteType } from './types';

// Sanitise a label down to [a-z0-9] (matches the port's first-word/label parsing).
function sanitise(raw: string | undefined): string {
  if (!raw) return '';
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '')
    .slice(0, 24);
}

/**
 * Classify OSM features into candidate keysites. Resilient to messy/missing tags:
 * unmatched features are dropped and names fall back to `<type><index>`.
 */
export function classifyFeatures(features: OsmFeature[]): CandidateKeysite[] {
  const raw: CandidateKeysite[] = [];
  const typeCounts: Partial<Record<KeysiteType, number>> = {};

  for (const f of features) {
    const c = classifyOsmSite(f.tags, f.id, f.name);
    if (f.kind && c?.type !== f.kind) {
      throw new Error(`OSM keysite kind mismatch for ${f.id}: export=${f.kind}, classifier=${c?.type ?? 'none'}`);
    }
    if (!c) continue;
    const idx = (typeCounts[c.type] ?? 0) + 1;
    typeCounts[c.type] = idx;
    const name = sanitise(f.name) || `${c.type}${idx}`;
    raw.push({ type: c.type, latlon: f.latlon, name, score: c.score, source: f });
  }

  raw.sort((a, b) => b.score - a.score || a.source.id.localeCompare(b.source.id));
  return raw;
}
