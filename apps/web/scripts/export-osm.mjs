import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import readline from 'node:readline';
import { booleanIntersects, simplify } from '@turf/turf';

const APP_ROOT = path.resolve(import.meta.dirname, '..');
const THEATRE_DIR = path.join(APP_ROOT, 'src', 'theatres');
const OUTPUT_DIR = path.join(APP_ROOT, 'src', 'osm');
const WORK_DIR = path.join(APP_ROOT, '.osm-work');
const PLANET_PATH = process.env.OSM_PLANET_PATH ?? 'E:\\planet-latest.osm.pbf';
const OSMIUM_IMAGE = process.env.OSMIUM_IMAGE ?? 'falcon-osm-osmium:latest';
const requested = new Set(process.argv.slice(2).map((value) => value.toLowerCase()));

const FILTERS = [
  'nwr/aeroway=aerodrome,heliport',
  'nwr/military=airfield,radar_station,depot,ammunition,bunker,barracks',
  'nwr/man_made=works,petroleum_refinery,radar,power_station,storage_tank,tank_farm,pier',
  'nwr/landuse=industrial,harbour,depot',
  'nwr/harbour=yes',
  'nwr/amenity=ferry_terminal,fuel',
  'nwr/tower:type=radar',
  'nwr/power=plant,substation',
  'nwr/office=government',
  'n/place=city,town,village,hamlet,locality',
  'n/natural=peak,saddle,ridge,valley,cliff',
  'n/mountain_pass=yes',
  'nwr/waterway=dam',
  'nwr/historic=fort,castle',
];
const ADM2_FILTERS = ['r/admin_level=6'];
const KEPT_TAGS = new Set([
  'name', 'operator', 'aeroway', 'aerodrome:type', 'icao', 'iata', 'military',
  'man_made', 'product', 'industrial', 'landuse', 'harbour', 'amenity',
  'tower:type', 'power', 'office', 'substance', 'resource', 'place', 'natural',
  'mountain_pass', 'waterway', 'historic',
]);
const ADMIN_BOUNDARY_TAGS = new Set([
  'name', 'name:en', 'official_name', 'boundary', 'admin_level', 'ISO3166-2',
  'wikidata', 'wikipedia', 'ref', 'type',
]);

function supported(tags) {
  const named = typeof tags.name === 'string' && tags.name.length > 0;
  return /^(aerodrome|heliport)$/.test(tags.aeroway ?? '') ||
    /^(airfield|radar_station|depot|ammunition|bunker|barracks)$/.test(tags.military ?? '') ||
    /^(works|petroleum_refinery|radar|power_station|storage_tank|tank_farm|pier)$/.test(tags.man_made ?? '') ||
    /^(industrial|harbour|depot)$/.test(tags.landuse ?? '') ||
    tags.harbour === 'yes' || /^(ferry_terminal|fuel)$/.test(tags.amenity ?? '') ||
    tags['tower:type'] === 'radar' || /^(plant|substation)$/.test(tags.power ?? '') ||
    tags.office === 'government' ||
    (named && /^(city|town|village|hamlet|locality)$/.test(tags.place ?? '')) ||
    (named && /^(peak|saddle|ridge|valley|cliff)$/.test(tags.natural ?? '')) ||
    (named && tags.mountain_pass === 'yes') || (named && tags.waterway === 'dam') ||
    (named && /^(fort|castle)$/.test(tags.historic ?? ''));
}

function compactTags(tags) {
  return Object.fromEntries(Object.entries(tags).filter(([key]) => KEPT_TAGS.has(key)));
}

function compactAdminBoundaryTags(tags) {
  return Object.fromEntries(Object.entries(tags).filter(([key]) => ADMIN_BOUNDARY_TAGS.has(key)));
}

/** Osmium encodes multipolygon relation areas as a<2 * relationId + 1>. */
function administrativeRelationId(value) {
  const directMatch = /^(?:relation\/|r)(\d+)$/.exec(value);
  if (directMatch) return `relation/${directMatch[1]}`;
  const areaMatch = /^a(\d+)$/.exec(value);
  if (!areaMatch) return null;
  const areaId = Number(areaMatch[1]);
  if (!Number.isSafeInteger(areaId) || areaId % 2 === 0) return null;
  return `relation/${(areaId - 1) / 2}`;
}

function terrainFeature(data) {
  if (data.type === 'Feature') return data;
  return data.features.find((feature) => feature.properties?.type === 'TERRAIN');
}

function inside([lon, lat], ring) {
  let result = false;
  for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index++) {
    const [x1, y1] = ring[index];
    const [x2, y2] = ring[previous];
    if ((y1 > lat) !== (y2 > lat) && lon < ((x2 - x1) * (lat - y1)) / (y2 - y1) + x1) {
      result = !result;
    }
  }
  return result;
}

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function runOsmium(workDirectory, args) {
  const dockerArgs = [
    'run', '--rm',
    '-v', `${path.resolve(PLANET_PATH)}:/data/planet.osm.pbf:ro`,
    '-v', `${path.resolve(workDirectory)}:/work`,
    OSMIUM_IMAGE,
    'osmium', ...args,
  ];
  await new Promise((resolve, reject) => {
    const child = spawn('docker', dockerArgs, { stdio: 'inherit', shell: false });
    child.once('error', reject);
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`Osmium exited ${code}`)));
  });
}

function collectCoordinates(value, result) {
  if (!Array.isArray(value)) return;
  if (value.length >= 2 && typeof value[0] === 'number' && typeof value[1] === 'number') {
    result.push([value[0], value[1]]);
    return;
  }
  for (const child of value) collectCoordinates(child, result);
}

function representativePoint(geometry) {
  if (!geometry) return null;
  if (geometry.type === 'Point') return geometry.coordinates;
  const coordinates = [];
  collectCoordinates(geometry.coordinates, coordinates);
  if (coordinates.length === 0) return null;
  const lons = coordinates.map(([lon]) => lon);
  const lats = coordinates.map(([, lat]) => lat);
  return [
    (Math.min(...lons) + Math.max(...lons)) / 2,
    (Math.min(...lats) + Math.max(...lats)) / 2,
  ];
}

async function* readGeoJsonSequence(file) {
  const lines = readline.createInterface({ input: createReadStream(file), crlfDelay: Infinity });
  for await (const line of lines) {
    const value = line.trim().replace(/^\u001e/, '');
    if (value) yield JSON.parse(value);
  }
}

async function exportTheatre(fileName) {
  const data = JSON.parse(await readFile(path.join(THEATRE_DIR, fileName), 'utf8'));
  const terrain = terrainFeature(data);
  if (!terrain) throw new Error(`${fileName} has no TERRAIN feature`);
  const theatre = terrain.properties.id;
  if (requested.size > 0 && !requested.has(theatre.toLowerCase())) return;

  const theatreWork = path.join(WORK_DIR, theatre);
  await mkdir(theatreWork, { recursive: true });
  await mkdir(OUTPUT_DIR, { recursive: true });
  const polygonPath = path.join(theatreWork, 'polygon.geojson');
  const regionPath = path.join(theatreWork, 'region.osm.pbf');
  const rawGeoJsonPath = path.join(theatreWork, 'filtered.geojson');
  const adminBoundaryGeoJsonPath = path.join(theatreWork, 'admin-boundaries.geojsonseq');
  await writeFile(polygonPath, JSON.stringify({
    type: 'FeatureCollection',
    features: [{ type: 'Feature', properties: {}, geometry: terrain.geometry }],
  }));

  if (!(await exists(regionPath))) {
    console.log(`[${theatre}] extracting theatre polygon from ${PLANET_PATH}`);
    await runOsmium(theatreWork, [
      'extract', '-p', '/work/polygon.geojson', '-s', 'smart',
      '/data/planet.osm.pbf', '-o', '/work/region.osm.pbf', '--overwrite', '--progress',
    ]);
  }
  console.log(`[${theatre}] filtering objective and keysite tags`);
  await runOsmium(theatreWork, [
    'tags-filter', '/work/region.osm.pbf', ...FILTERS,
    '-o', '/work/filtered.osm.pbf', '--overwrite', '--progress',
  ]);
  console.log(`[${theatre}] exporting filtered geometry`);
  await runOsmium(theatreWork, [
    'export', '/work/filtered.osm.pbf', '-o', '/work/filtered.geojson',
    '--overwrite', '--add-unique-id=type_id', '--progress',
  ]);
  console.log(`[${theatre}] filtering district-level administrative boundaries`);
  await runOsmium(theatreWork, [
    'tags-filter', '/work/region.osm.pbf', ...ADM2_FILTERS,
    '-o', '/work/admin-boundaries.osm.pbf', '--overwrite', '--progress',
  ]);
  console.log(`[${theatre}] exporting administrative boundary geometry`);
  await runOsmium(theatreWork, [
    'export', '/work/admin-boundaries.osm.pbf', '-f', 'geojsonseq',
    '-o', '/work/admin-boundaries.geojsonseq', '--geometry-types=polygon',
    '--overwrite', '--add-unique-id=type_id', '--progress',
  ]);

  const raw = JSON.parse(await readFile(rawGeoJsonPath, 'utf8'));
  const ring = terrain.geometry.coordinates[0];
  const theatreFeature = { type: 'Feature', properties: {}, geometry: terrain.geometry };
  const features = [];
  for (const feature of raw.features ?? []) {
    const point = representativePoint(feature.geometry);
    if (!point || !inside(point, ring)) continue;
    const rawTags = { ...(feature.properties ?? {}) };
    const osmId = String(feature.id ?? rawTags['@id'] ?? rawTags.id ?? '');
    delete rawTags['@id'];
    delete rawTags.id;
    if (!osmId || !supported(rawTags)) continue;
    const tags = compactTags(rawTags);
    features.push({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: point },
      properties: { osmId, ...(tags.name ? { name: tags.name } : {}), tags },
    });
  }
  const pointCount = features.length;
  let adminBoundaryCount = 0;
  for await (const feature of readGeoJsonSequence(adminBoundaryGeoJsonPath)) {
    if (!feature.geometry || !['Polygon', 'MultiPolygon'].includes(feature.geometry.type)) continue;
    const rawTags = { ...(feature.properties ?? {}) };
    const osmId = administrativeRelationId(String(feature.id ?? rawTags['@id'] ?? rawTags.id ?? ''));
    delete rawTags['@id'];
    delete rawTags.id;
    if (
      !osmId ||
      rawTags.boundary !== 'administrative' ||
      rawTags.admin_level !== '6' ||
      !booleanIntersects(feature, theatreFeature)
    ) continue;
    const coarse = simplify(feature, { tolerance: 0.003, highQuality: false, mutate: false });
    const tags = compactAdminBoundaryTags(rawTags);
    features.push({
      type: 'Feature',
      geometry: coarse.geometry,
      properties: {
        kind: 'admin-boundary',
        adminLevel: 6,
        osmId,
        name: tags['name:en'] ?? tags.name ?? tags.official_name ?? '',
        tags,
      },
    });
    adminBoundaryCount += 1;
  }
  features.sort((a, b) => a.properties.osmId.localeCompare(b.properties.osmId));
  const output = {
    type: 'FeatureCollection',
    properties: {
      theatre,
      source: '© OpenStreetMap contributors',
      exportedAt: new Date().toISOString(),
      planetFile: path.basename(PLANET_PATH),
    },
    features,
  };
  await writeFile(path.join(OUTPUT_DIR, `${theatre}.geojson`), JSON.stringify(output));
  console.log(`[${theatre}] wrote ${pointCount} point features and ${adminBoundaryCount} ADM2-style boundaries`);
}

await access(PLANET_PATH);
for (const fileName of await readdir(THEATRE_DIR)) {
  if (fileName.toLowerCase().endsWith('.geojson')) await exportTheatre(fileName);
}
