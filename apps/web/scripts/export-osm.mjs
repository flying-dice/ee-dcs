import { spawn } from 'node:child_process';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { gzipSync } from 'node:zlib';
import { area as polygonArea, bbox, booleanPointInPolygon, centerOfMass, pointOnFeature } from '@turf/turf';
import { classifyOsmSite } from '../src/lib/osm-policy.mjs';

const APP_ROOT = path.resolve(import.meta.dirname, '..');
const THEATRE_DIR = path.join(APP_ROOT, 'src', 'theatres');
const OUTPUT_DIR = path.join(APP_ROOT, 'public', 'osm');
const WORK_DIR = path.join(APP_ROOT, '.osm-work');
const PLANET_PATH = process.env.OSM_PLANET_PATH ?? 'E:\\planet-latest.osm.pbf';
const OSMIUM_IMAGE = process.env.OSMIUM_IMAGE ?? 'falcon-osm-osmium:latest';
const requested = new Set(process.argv.slice(2).map((value) => value.toLowerCase()));
const fromCache = requested.delete('--from-cache');

const FILTERS = [
  'nwr/military',
  'nwr/landuse=military',
  'nwr/man_made=works,petroleum_refinery,radar,power_station,tank_farm',
  'nwr/industrial=oil,refinery,port,factory',
  'nwr/industrial=warehouse',
  'nwr/building=warehouse',
  'nwr/building:use=warehouse',
  'nwr/amenity=warehouse',
  'nwr/amenity=townhall,community_centre',
  'nwr/office=government',
  'nwr/building=government,government_office,civic',
  'nwr/landuse=industrial,harbour,depot',
  'nwr/harbour=yes',
  'nwr/amenity=ferry_terminal',
  'nwr/power=plant,substation',
];
const KEPT_TAGS = new Set([
  'name', 'name:en', 'official_name:en', 'int_name', 'military',
  'man_made', 'product', 'industrial', 'landuse', 'harbour', 'amenity',
  'building', 'building:use', 'office',
  'power', 'substation', 'voltage', 'plant:output:electricity', 'substance', 'resource',
]);

function nonemptyName(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function preferredName(tags) {
  return nonemptyName(tags['name:en']) ?? nonemptyName(tags['official_name:en']) ??
    nonemptyName(tags.int_name) ?? nonemptyName(tags.name);
}

function compactTags(tags) {
  return Object.fromEntries(Object.entries(tags).filter(([key]) => KEPT_TAGS.has(key)));
}

function siteFootprint(tags) {
  return ['industrial', 'military', 'harbour', 'depot'].includes(tags.landuse) ||
    ['plant', 'substation'].includes(tags.power) ||
    ['base', 'naval_base'].includes(tags.military);
}

function insideBounds([lon, lat], bounds) {
  return lon >= bounds[0] && lon <= bounds[2] && lat >= bounds[1] && lat <= bounds[3];
}

// Buildings and nodes describe a component of a mapped site, not another spawn site.
// Keep every distinct site footprint, including nested industrial landuse polygons.
function preferSiteFootprints(candidates) {
  const grounds = new Map();
  for (const candidate of candidates) {
    if (!candidate.siteFootprint) continue;
    const kind = candidate.point.properties.kind;
    if (!grounds.has(kind)) grounds.set(kind, []);
    grounds.get(kind).push(candidate);
  }
  return candidates.filter((candidate) => {
    if (candidate.siteFootprint) return true;
    const point = candidate.point.geometry.coordinates;
    return !(grounds.get(candidate.point.properties.kind) ?? []).some((ground) =>
      ground.point.properties.osmId !== candidate.point.properties.osmId &&
      insideBounds(point, ground.bounds) && booleanPointInPolygon(point, ground.source),
    );
  });
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

// Match the airfield envelope shown as the dashed active-area rectangle in the UI.
function activeBounds(data, ring) {
  const lons = ring.map(([lon]) => lon);
  const lats = ring.map(([, lat]) => lat);
  const bounds = [Math.min(...lons), Math.min(...lats), Math.max(...lons), Math.max(...lats)];
  const airbases = (data.features ?? []).filter((feature) =>
    feature.properties?.type === 'AIRBASE' && feature.geometry?.type === 'Point',
  );
  if (airbases.length === 0) return bounds;
  const airLons = airbases.map((feature) => feature.geometry.coordinates[0]);
  const airLats = airbases.map((feature) => feature.geometry.coordinates[1]);
  const centreLat = (Math.min(...airLats) + Math.max(...airLats)) / 2;
  const latPadding = 100 / 111.32;
  const lonPadding = 100 / (111.32 * Math.max(0.2, Math.cos(centreLat * Math.PI / 180)));
  return [
    Math.max(bounds[0], Math.min(...airLons) - lonPadding),
    Math.max(bounds[1], Math.min(...airLats) - latPadding),
    Math.min(bounds[2], Math.max(...airLons) + lonPadding),
    Math.min(bounds[3], Math.max(...airLats) + latPadding),
  ];
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
  await writeFile(polygonPath, JSON.stringify({
    type: 'FeatureCollection',
    features: [{ type: 'Feature', properties: {}, geometry: terrain.geometry }],
  }));

  if (!fromCache && !(await exists(regionPath))) {
    console.log(`[${theatre}] extracting theatre polygon from ${PLANET_PATH}`);
    await runOsmium(theatreWork, [
      'extract', '-p', '/work/polygon.geojson', '-s', 'smart',
      '/data/planet.osm.pbf', '-o', '/work/region.osm.pbf', '--overwrite', '--progress',
    ]);
  }
  if (!fromCache) {
    console.log(`[${theatre}] filtering keysite tags`);
    await runOsmium(theatreWork, [
      'tags-filter', '/work/region.osm.pbf', ...FILTERS,
      '-o', '/work/filtered.osm.pbf', '--overwrite', '--progress',
    ]);
    console.log(`[${theatre}] exporting filtered geometry`);
    await runOsmium(theatreWork, [
      'export', '/work/filtered.osm.pbf', '-o', '/work/filtered.geojson',
      '--overwrite', '--add-unique-id=type_id', '--progress',
    ]);
  } else if (!(await exists(rawGeoJsonPath))) {
    throw new Error(`[${theatre}] --from-cache needs filtered.geojson`);
  }

  const raw = JSON.parse(await readFile(rawGeoJsonPath, 'utf8'));
  const ring = terrain.geometry.coordinates[0];
  const bounds = activeBounds(data, ring);
  const features = [];
  for (const feature of raw.features ?? []) {
    const rawTags = { ...(feature.properties ?? {}) };
    const osmId = String(feature.id ?? rawTags['@id'] ?? rawTags.id ?? '');
    delete rawTags['@id'];
    delete rawTags.id;
    const tags = compactTags(rawTags);
    const name = preferredName(tags);
    const classification = classifyOsmSite(tags, osmId, name ?? undefined);
    const sourceName = nonemptyName(tags.name);
    if (!osmId || classification === null ||
      tags.landuse !== 'industrial' && (/^(aerodrome|heliport)$/.test(rawTags.aeroway ?? '') ||
        rawTags.military === 'airfield')) continue;
    const polygon = ['Polygon', 'MultiPolygon'].includes(feature.geometry?.type);
    const centre = polygon ? centerOfMass(feature).geometry.coordinates : null;
    const point = polygon && centre && booleanPointInPolygon(centre, feature)
      ? centre : feature.geometry ? pointOnFeature(feature).geometry.coordinates : null;
    if (!point || !inside(point, ring)) continue;
    const footprintM2 = polygon ? polygonArea(feature) : 0;
    const civicSite = classification.type === 'command' &&
      (tags.office === 'government' || ['government', 'government_office', 'civic'].includes(tags.building) ||
        tags.amenity === 'townhall' || tags.amenity === 'community_centre');
    if (civicSite && tags.landuse !== 'industrial' &&
      footprintM2 < (tags.amenity === 'townhall' ? 750 : 1500)) continue;
    const pointFeature = {
      type: 'Feature',
      geometry: { type: 'Point', coordinates: point },
      properties: {
        osmId, kind: classification.type, name: name ?? (
          classification.type === 'power' ? 'Transmission substation' :
            classification.type === 'command' ? (civicSite ? 'Government building' : 'Military site') :
            classification.type === 'depot' ? 'Warehouse' : 'Industrial site'),
        ...(sourceName && sourceName !== name ? { sourceName } : {}),
        tags,
      },
    };
    features.push({
      point: pointFeature,
      source: feature,
      siteFootprint: polygon && siteFootprint(tags),
      bounds: polygon ? bbox(feature) : null,
    });
  }
  // Osmium emits a closed way both as a line (w<ID>) and an area (a<2*ID>).
  // The area is the useful site footprint, so never expose its duplicate line.
  const areaWayIds = new Set(features.flatMap((feature) => {
    const match = /^a(\d+)$/.exec(feature.point.properties.osmId);
    if (!match) return [];
    const id = BigInt(match[1]);
    return id % 2n === 0n ? [`w${id / 2n}`] : [];
  }));
  const selected = features.filter((feature) => !areaWayIds.has(feature.point.properties.osmId));
  const active = selected.filter((feature) => {
    return insideBounds(feature.point.geometry.coordinates, bounds);
  });
  const siteCandidates = preferSiteFootprints(active).map((candidate) => candidate.point);
  siteCandidates.sort((a, b) => a.properties.osmId.localeCompare(b.properties.osmId));
  const output = {
    type: 'FeatureCollection',
    properties: {
      theatre,
      source: '© OpenStreetMap contributors',
    },
    features: siteCandidates,
  };
  const encoded = gzipSync(Buffer.from(JSON.stringify(output)), { level: 9, mtime: 0 });
  await writeFile(path.join(OUTPUT_DIR, `${theatre}.geojson.gz`), encoded);
  console.log(`[${theatre}] wrote ${siteCandidates.length} active-area point candidates (${encoded.length} gzip bytes)`);
}

if (!fromCache) await access(PLANET_PATH);
for (const fileName of await readdir(THEATRE_DIR)) {
  if (fileName.toLowerCase().endsWith('.geojson')) await exportTheatre(fileName);
}
