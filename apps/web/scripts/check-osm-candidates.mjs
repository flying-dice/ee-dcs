import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import path from 'node:path';
import { gunzipSync } from 'node:zlib';
import { booleanPointInPolygon, centerOfMass, pointOnFeature } from '@turf/turf';
import { classifyOsmSite } from '../src/lib/osm-policy.mjs';

const area = 'a1234';
const cases = [
  ['factory', { industrial: 'factory' }, 'Metal Factory'],
  ['factory', { man_made: 'works', product: 'steel' }, 'Steel Works'],
  [null, { man_made: 'works', product: 'oil' }, 'Oil Works'],
  [null, { man_made: 'works' }, 'Compressor Station'],
  ['factory', { landuse: 'industrial' }, 'Lazetti Tobacco'],
  [null, { industrial: 'factory' }, 'Organize Sanayi Bölgesi'],
  ['factory', { landuse: 'industrial' }, undefined],
  ['depot', { landuse: 'industrial', industrial: 'warehouse' }, undefined],
  ['depot', { building: 'warehouse' }, undefined],
  ['depot', { 'building:use': 'warehouse' }, 'Logistics building'],
  ['depot', { amenity: 'warehouse' }, 'Distribution site'],
  ['refinery', { industrial: 'oil' }, 'Afipsky Refinery'],
  [null, { industrial: 'oil' }, 'BTC Oil Pump Station'],
  ['fuel', { industrial: 'oil' }, 'Supsa Oil Terminal'],
  [null, { industrial: 'oil' }, 'Airport Fuel Depot'],
  ['power', { power: 'plant', 'plant:output:electricity': '100 MW' }, 'Power Plant'],
  ['power', { power: 'substation', substation: 'transmission', voltage: '220000' }, undefined],
  ['power', { power: 'substation', voltage: '330000;110000' }, 'Grid substation'],
  [null, { power: 'substation', substation: 'distribution', voltage: '110000;10000' }, 'Local substation'],
  [null, { power: 'substation', substation: 'minor_distribution', voltage: '400000' }, 'Mislabeled cabinet'],
  [null, { power: 'substation', substation: 'traction', voltage: '220000' }, 'Railway traction site'],
  [null, { power: 'substation' }, 'Unknown-voltage substation'],
  [null, { power: 'transformer', voltage: '400000' }, 'Transformer'],
  [null, { power: 'plant', 'plant:output:electricity': '99 MW' }, 'Small Power Plant'],
  [null, { power: 'generator', 'generator:output:electricity': '100 MW' }, 'Generator'],
  ['port', { amenity: 'ferry_terminal' }, 'Naval Station'],
  ['port', { industrial: 'port' }, 'Giresunport'],
  [null, { industrial: 'port' }, 'Tbilisi Dry Port'],
  [null, { industrial: 'port' }, 'Airport Radio Station'],
  ['radar', { military: 'radar_station' }, 'Air Defence Radar'],
  [null, { 'tower:type': 'radar' }, 'Weather Radar'],
  ['depot', { military: 'ammunition' }, 'Ammunition Depot'],
  [null, { landuse: 'depot' }, 'Trolleybus Depot'],
  ['command', { military: 'base' }, 'Military Base'],
  ['command', { military: 'base' }, undefined],
  ['command', { military: 'naval_base', landuse: 'military' }, 'Naval Base'],
  ['command', { military: 'barracks', landuse: 'military' }, undefined],
  ['command', { landuse: 'military' }, undefined],
  ['command', { building: 'government', office: 'government' }, 'Government House'],
  ['command', { amenity: 'townhall' }, 'City Hall'],
  ['command', { building: 'civic' }, 'Civic Centre'],
  [null, { building: 'civic' }, 'Civic Sports Centre'],
  [null, { military: 'bunker', landuse: 'military' }, 'Bunker'],
  [null, { military: 'danger_area', landuse: 'military' }, 'Firing Range'],
  ['depot', { military: 'depot' }, undefined],
  ['command', { military: 'barracks' }, 'Barracks'],
];

for (const [expected, tags, name] of cases) {
  assert.equal(classifyOsmSite(tags, area, name)?.type ?? null, expected, name);
}
assert.equal(classifyOsmSite({ power: 'substation', voltage: '220000' }, 'n1234', 'Point substation'), null);

const datasetPath = path.resolve(import.meta.dirname, '../public/osm/Caucasus.geojson.gz');
const dataset = JSON.parse(gunzipSync(await readFile(datasetPath)).toString('utf8'));
const counts = {};
const byId = new Map(dataset.features.map((feature) => [feature.properties.osmId, feature]));
assert.equal(byId.size, dataset.features.length, 'one dot per OSM source');
assert.equal(byId.get('a407808590')?.properties.kind, 'port', 'Naval Station');
assert.equal(byId.get('a116404378')?.properties.kind, 'refinery', 'Ilskiy refinery');
assert.equal(byId.get('a148621314')?.properties.kind, 'fuel', 'Supsa oil terminal');
assert.equal(byId.get('a547608858')?.properties.kind, 'factory', 'airport radio polygon is still industrial land');
assert.equal(byId.get('a2638703194')?.properties.kind, 'factory', 'Lazetti industrial land');
assert.equal(byId.get('a1340413738')?.properties.kind, 'power', 'Zugdidi 220kV transmission substation');
for (const feature of dataset.features) {
  assert.equal(feature.geometry.type, 'Point');
  const { osmId, name, tags, kind } = feature.properties;
  assert.ok(name?.trim(), osmId);
  assert.equal(classifyOsmSite(tags, osmId, name)?.type, kind, osmId);
  if (kind === 'power' && tags.power === 'substation') {
    assert.ok(tags.voltage?.split(';').some((value) => /^\d+$/.test(value.trim()) && Number(value.trim()) >= 220_000), osmId);
  }
  counts[kind] = (counts[kind] ?? 0) + 1;
}
assert.ok(counts.command >= 52, 'existing military command candidates retained');
assert.ok(dataset.features.some((feature) => feature.properties.kind === 'factory' && feature.properties.tags.landuse === 'industrial'));
assert.ok(dataset.features.some((feature) => feature.properties.kind === 'depot' && feature.properties.tags.building === 'warehouse'));
assert.ok(dataset.features.some((feature) => feature.properties.kind === 'command' && feature.properties.tags.landuse === 'military' && !feature.properties.tags.military));
assert.ok(dataset.features.some((feature) => feature.properties.kind === 'command' && feature.properties.tags.office === 'government'));
const theatre = JSON.parse(await readFile(path.resolve(import.meta.dirname, '../src/theatres/Caucasus.geojson'), 'utf8'));
const terrain = theatre.features.find((feature) => feature.properties?.type === 'TERRAIN');
const ring = terrain.geometry.coordinates[0];
const lons = ring.map(([lon]) => lon);
const lats = ring.map(([, lat]) => lat);
const airbases = theatre.features.filter((feature) => feature.properties?.type === 'AIRBASE' && feature.geometry?.type === 'Point');
const airLons = airbases.map((feature) => feature.geometry.coordinates[0]);
const airLats = airbases.map((feature) => feature.geometry.coordinates[1]);
const centreLat = (Math.min(...airLats) + Math.max(...airLats)) / 2;
const bounds = [
  Math.max(Math.min(...lons), Math.min(...airLons) - 100 / (111.32 * Math.max(0.2, Math.cos(centreLat * Math.PI / 180)))),
  Math.max(Math.min(...lats), Math.min(...airLats) - 100 / 111.32),
  Math.min(Math.max(...lons), Math.max(...airLons) + 100 / (111.32 * Math.max(0.2, Math.cos(centreLat * Math.PI / 180)))),
  Math.min(Math.max(...lats), Math.max(...airLats) + 100 / 111.32),
];
const inBounds = ([lon, lat]) => lon >= bounds[0] && lon <= bounds[2] && lat >= bounds[1] && lat <= bounds[3];
for (const feature of dataset.features) assert.ok(inBounds(feature.geometry.coordinates), feature.properties.osmId);
const rawPath = path.resolve(import.meta.dirname, '../.osm-work/Caucasus/filtered.geojson');
try {
  await access(rawPath);
  const raw = JSON.parse(await readFile(rawPath, 'utf8'));
  const inside = ([lon, lat]) => {
    let result = false;
    for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index++) {
      const [x1, y1] = ring[index];
      const [x2, y2] = ring[previous];
      if ((y1 > lat) !== (y2 > lat) && lon < ((x2 - x1) * (lat - y1)) / (y2 - y1) + x1) result = !result;
    }
    return result;
  };
  let industrialAreas = 0;
  for (const feature of raw.features) {
    if (feature.properties?.landuse !== 'industrial' ||
      !['Polygon', 'MultiPolygon'].includes(feature.geometry?.type)) continue;
    const centre = centerOfMass(feature).geometry.coordinates;
    const point = booleanPointInPolygon(centre, feature) ? centre : pointOnFeature(feature).geometry.coordinates;
    if (!inside(point) || !inBounds(point)) continue;
    industrialAreas++;
    assert.ok(byId.has(String(feature.id)), `missing industrial area ${feature.id}`);
  }
  assert.ok(industrialAreas > 0);
  console.log(`Verified every one of ${industrialAreas} active-area industrial polygons is exported`);
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
console.log(`PASS ${cases.length} policy cases; ${dataset.features.length} candidates`, counts);
