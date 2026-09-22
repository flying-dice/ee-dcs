import assert from 'node:assert/strict';
import { createServer } from 'vite';
import { latLngToCell } from 'h3-js';

const server = await createServer({ configFile: false, server: { middlewareMode: true } });
try {
  const { createDesignGeoJson, parseDesignGeoJson } = await server.ssrLoadModule('/src/lib/design-geojson.ts');
  const { DEFAULT_COUNTS } = await server.ssrLoadModule('/src/lib/balance.ts');
  const { DEFAULT_UNIT_TYPES } = await server.ssrLoadModule('/src/lib/units.ts');
  const cell = latLngToCell(41.6, 41.6, 5);
  const state = {
    terrainId: 'Caucasus',
    cellAssignments: { [cell]: { side: 'blue', role: 'rear' } },
    mainBlueId: 'ab:Batumi', mainRedId: null,
    populated: true,
    counts: structuredClone(DEFAULT_COUNTS),
    draftCounts: structuredClone(DEFAULT_COUNTS),
    seed: 17,
    removed: ['osm:a123'],
    added: [{ id: 'osm:a456', type: 'factory', side: 'blue', latlon: { lat: 41.6, lon: 41.6 }, name: 'Factory', tags: { landuse: 'industrial' } }],
    positionOverrides: { 'farp:one': { lat: 41.6, lon: 41.6 } },
    bakeCampaign: false,
    unitTypes: structuredClone(DEFAULT_UNIT_TYPES),
    assignmentSide: 'red', assignmentRole: 'close', paintErase: true,
  };
  const keysite = { id: 'osm:a456', type: 'factory', side: 'blue', latlon: { lat: 41.6, lon: 41.6 }, name: 'Factory' };
  const zone = { zoneId: 2001, name: 'factory_Factory', x: 12, y: 34, radius: 1000, color: [0, 0, 1, 1], side: 'blue', type: 'factory' };
  const saved = createDesignGeoJson(state, [keysite], [zone]);
  assert.equal(saved.type, 'FeatureCollection');
  assert.equal(saved.features.length, 2);
  assert.equal(saved.features[0].geometry.type, 'Polygon');
  assert.deepEqual(saved.features[0].geometry.coordinates[0][0], saved.features[0].geometry.coordinates[0].at(-1));
  assert.equal(saved.features[1].geometry.type, 'Point');
  assert.deepEqual(parseDesignGeoJson(JSON.parse(JSON.stringify(saved))), [state, null]);

  const changed = (edit) => { const copy = structuredClone(saved); edit(copy); return copy; };
  assert.match(parseDesignGeoJson({ type: 'FeatureCollection', features: [] })[1], /not an EE-DCS/);
  assert.match(parseDesignGeoJson(changed((copy) => { copy.properties.version = 99; }))[1], /unsupported version/);
  assert.match(parseDesignGeoJson(changed((copy) => { copy.properties.h3Resolution = 6; }))[1], /different H3 level/);
  assert.match(parseDesignGeoJson(changed((copy) => { copy.features.push(copy.features[0]); }))[1], /duplicate painted/);
  assert.match(parseDesignGeoJson(changed((copy) => { copy.properties.state.counts.factory.blue = -1; }))[1], /invalid generator settings/);
  assert.match(parseDesignGeoJson(changed((copy) => { copy.features[0].geometry.coordinates[0][0] = [999, 999]; }))[1], /invalid or duplicate painted/);
  console.log('PASS GeoJSON design save/load round-trip and six invalid-file cases');
} finally {
  await server.close();
}
