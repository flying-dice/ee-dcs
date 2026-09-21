// ── Precompiled OSM data source ─────────────────────────────────────────────────
// Theatre datasets are generated at development time by scripts/precompile-osm.mjs.
// The browser only loads the matching static asset and filters it to the authored AO.

import type { AdminBoundary, ObjectiveFeature, OsmFeature } from './types';

const compiledFiles = import.meta.glob('../osm/*.geojson', {
  query: '?url',
  import: 'default',
}) as Record<string, () => Promise<string>>;

export async function loadTheatreOsm(
  theatreId: string,
): Promise<{ features: OsmFeature[]; adminBoundaries: AdminBoundary[] }> {
  const entry = Object.entries(compiledFiles).find(([path]) =>
    path.toLowerCase().endsWith(`/${theatreId.toLowerCase()}.geojson`),
  );
  if (!entry) throw new Error(`No compiled OSM dataset for ${theatreId}`);
  const url = await entry[1]();
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Could not load the compiled OSM export for ${theatreId}`);
  const raw = await response.text();
  const data = JSON.parse(raw) as {
    type: 'FeatureCollection';
    features: Array<{
      geometry:
        | { type: 'Point'; coordinates: [number, number] }
        | AdminBoundary['geometry'];
      properties: {
        kind?: 'admin-boundary';
        adminLevel?: number;
        osmId: string;
        name?: string;
        tags: Record<string, string>;
      };
    }>;
  };
  const features: OsmFeature[] = [];
  const adminBoundaries: AdminBoundary[] = [];
  for (const feature of data.features) {
    if (
      feature.properties.kind === 'admin-boundary' &&
      feature.geometry.type !== 'Point' &&
      typeof feature.properties.adminLevel === 'number'
    ) {
      adminBoundaries.push({
        id: feature.properties.osmId,
        name: feature.properties.name ?? '',
        adminLevel: feature.properties.adminLevel,
        geometry: feature.geometry,
        tags: feature.properties.tags,
      });
    } else if (feature.geometry.type === 'Point') {
      features.push({
        id: feature.properties.osmId,
        latlon: { lat: feature.geometry.coordinates[1], lon: feature.geometry.coordinates[0] },
        tags: feature.properties.tags,
        name: feature.properties.name,
      });
    }
  }
  return { features, adminBoundaries };
}

/** Keep named places and defensible terrain features as objective anchors. */
export function extractObjectiveFeatures(features: OsmFeature[]): ObjectiveFeature[] {
  const result: ObjectiveFeature[] = [];
  for (const feature of features) {
    const name = feature.name?.trim();
    if (!name) continue;
    const tags = feature.tags;
    const settlement = /^(city|town|village|hamlet|locality)$/.test(tags.place ?? '');
    const keyTerrain =
      /^(peak|saddle|ridge|valley|cliff)$/.test(tags.natural ?? '') ||
      tags.mountain_pass === 'yes' ||
      tags.waterway === 'dam' ||
      /^(fort|castle)$/.test(tags.historic ?? '');
    if (!settlement && !keyTerrain) continue;
    result.push({
      id: feature.id,
      kind: settlement ? 'settlement' : 'key-terrain',
      name,
      latlon: feature.latlon,
      tags,
    });
  }
  return result.sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
}
