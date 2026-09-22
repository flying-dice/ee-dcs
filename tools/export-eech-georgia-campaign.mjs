import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const GAME_ROOT = 'D:/Program Files (x86)/GOG Galaxy/Games/Comanche vs Hokum';
const MAP_ROOT = path.join(GAME_ROOT, 'common/maps/map3');
const CAMPAIGN_ROOT = path.join(MAP_ROOT, 'camp01');
const OUTPUT = path.resolve(import.meta.dirname, '../docs/eech-georgia-caspian-black-gold.geojson');
const SOURCE_ANCHORS_OUTPUT = path.resolve(import.meta.dirname, '../docs/eech-georgia-caspian-black-gold-source-anchors.geojson');

// EECH map 3's origin, from modules/graphics/textuser.c.  The conversion is
// the same ellipsoidal metres-per-degree calculation used by tacview.c.
const MAP_MAX_Z = 58 * 4096;
const LATITUDE_ORIGIN = 41.16;
const LONGITUDE_ORIGIN = 40.185;
const M1 = 111132.92;
const M2 = -559.82;
const M3 = 1.175;
const P1 = 111412.84;
const P2 = -93.5;

const templateTypes = [
  'invalid', 'space', 'housing', 'office', 'industry', 'cultural', 'church',
  'outskirts', 'airfield', 'aaa_sam', 'port_se', 'port_nw', 'military',
  'farm', 'oil', 'key_power', 'key_radio', 'key_industry', 'key_port',
  'key_military', 'key_oil', 'construct', 'ruin', 'water', 'road_x',
  'road_junction_n', 'road_junction_s', 'road_junction_e', 'road_junction_w',
  'road_cross', 'road_z', 'road',
];

function rad(degrees) {
  return degrees * Math.PI / 180;
}

function coordinate(x, z) {
  const latitudeLength = M1 + M2 * Math.cos(2 * rad(LATITUDE_ORIGIN)) + M3 * Math.cos(4 * rad(LATITUDE_ORIGIN));
  const latitude = LATITUDE_ORIGIN + z / latitudeLength;
  const longitudeLength = P1 * Math.cos(rad(Math.abs(latitude))) + P2 * Math.cos(3 * rad(Math.abs(latitude)));
  return [Number((LONGITUDE_ORIGIN + x / longitudeLength).toFixed(6)), Number(latitude.toFixed(6))];
}

function feature(properties, x, z) {
  return {
    type: 'Feature',
    properties: {
      ...properties,
      eech_world_x_metres: x,
      eech_world_z_metres: z,
    },
    geometry: x === null || z === null ? null : { type: 'Point', coordinates: coordinate(x, z) },
  };
}

function sourceAnchorFeature(properties, x, z) {
  return feature({
    ...properties,
    map_display: 'source_anchor_only',
    geometry_note: 'EECH city-template origins are not geographic object locations. Use eech_world_*_metres to render these against the EECH map, or use the source-anchors companion file only for source inspection.',
  }, x, z);
}

function readString(reader) {
  const length = reader.readInt32LE();
  const value = reader.readString(length);
  return value.replace(/\0+$/, '');
}

class BinaryReader {
  constructor(buffer) {
    this.buffer = buffer;
    this.offset = 0;
  }

  readInt32LE() {
    const value = this.buffer.readInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readFloatLE() {
    const value = this.buffer.readFloatLE(this.offset);
    this.offset += 4;
    return value;
  }

  readString(length) {
    const value = this.buffer.toString('latin1', this.offset, this.offset + length);
    this.offset += length;
    return value;
  }
}

function parsePopulation(buffer) {
  const reader = new BinaryReader(buffer);
  let templateCount = reader.readInt32LE();
  const version2 = templateCount < 0;
  if (version2) templateCount = -templateCount;
  const templates = [];

  for (let index = 0; index < templateCount; index += 1) {
    const objectCount = reader.readInt32LE();
    const type = reader.readInt32LE();
    for (let slot = 0; slot < 2 + Number(version2); slot += 1) {
      if (reader.readInt32LE()) readString(reader);
    }
    for (let objectIndex = 0; objectIndex < objectCount; objectIndex += 1) {
      reader.readFloatLE();
      reader.readFloatLE();
      reader.readFloatLE();
      readString(reader);
    }
    templates.push({ index, type, typeName: templateTypes[type] ?? `unknown_${type}`, objectCount });
  }

  const cityCount = reader.readInt32LE();
  const cities = [];
  for (let index = 0; index < cityCount; index += 1) {
    const templateIndex = reader.readInt32LE();
    const x = reader.readFloatLE();
    const rawZ = reader.readFloatLE();
    cities.push({ index, templateIndex, x, z: MAP_MAX_Z - rawZ });
  }

  const airfieldCount = reader.readInt32LE();
  const airfields = [];
  for (let index = 0; index < airfieldCount; index += 1) {
    const x = reader.readFloatLE();
    const rawZ = reader.readFloatLE();
    airfields.push({ index, x, z: MAP_MAX_Z - rawZ, shape: readString(reader) });
  }

  const samCount = reader.readInt32LE();
  const sams = [];
  for (let index = 0; index < samCount; index += 1) {
    const x = reader.readFloatLE();
    const rawZ = reader.readFloatLE();
    sams.push({ index, x, z: MAP_MAX_Z - rawZ });
  }

  if (reader.offset !== buffer.length) throw new Error(`Unexpected trailing data: ${buffer.length - reader.offset} bytes`);
  return { version2, templates, cities, airfields, sams };
}

function parsePopulationNames(text) {
  const records = [];
  for (const section of text.split(/:NAME /).slice(1)) {
    const name = section.split(/\r?\n/, 1)[0].trim();
    const type = /^:POPULATION_TYPE (.+)$/m.exec(section)?.[1];
    const position = /^:POSITION\s+([\d.]+)\s+([\d.]+)\s*$/m.exec(section);
    if (type && position) records.push({ name, type: type.trim(), x: Number(position[1]), z: Number(position[2]) });
  }
  return records;
}

function parseCampaign(text) {
  const title = /^:TITLE (.+)$/m.exec(text)?.[1] ?? 'Georgia campaign';
  const records = [];
  let side = null;
  const lines = text.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const sideMatch = /^:SIDE (.+)$/.exec(lines[index]);
    if (sideMatch) side = sideMatch[1];
    const keysiteMatch = /^:KEYSITE (.+)$/.exec(lines[index]);
    if (!keysiteMatch) continue;
    const block = lines.slice(index, lines.findIndex((line, next) => next > index && (/^:KEYSITE /.test(line) || /^:FACTION$/.test(line))));
    const name = /^:NAME (.+)$/m.exec(block.join('\n'))?.[1];
    if (name) records.push({ name, side, keysiteType: keysiteMatch[1], mobile: /^:MOBILE_KEYSITE$/m.test(block.join('\n')), startBase: /^:START_BASE$/m.test(block.join('\n')) });
  }
  return { title, records };
}

function nearestNamedLocation(airfield, names) {
  const candidate = names
    .map((name) => ({ name, distance: Math.hypot(airfield.x - name.x, airfield.z - name.z) }))
    .sort((left, right) => left.distance - right.distance)[0];
  return candidate && candidate.distance <= 3000 ? candidate.name.name : null;
}

function airfieldKind(shape) {
  if (/FARP/i.test(shape)) return 'farp';
  if (/AIRPORT|AIRSTRIP/i.test(shape)) return 'airbase';
  return 'airfield_placement';
}

const [campaignText, namesText, populationBuffer] = await Promise.all([
  readFile(path.join(CAMPAIGN_ROOT, 'GEORGIA.CHC'), 'utf8'),
  readFile(path.join(MAP_ROOT, 'route/POPNAME.DAT'), 'utf8'),
  readFile(path.join(CAMPAIGN_ROOT, 'GEORGIA.BIN')),
]);
const campaign = parseCampaign(campaignText);
const names = parsePopulationNames(namesText);
const population = parsePopulation(populationBuffer);
const campaignByName = new Map(campaign.records.map((record) => [record.name, record]));
const features = [];
const sourceAnchorFeatures = [];

for (const record of campaign.records) {
  const named = names.find((entry) => entry.name === record.name);
  features.push(feature({ record_kind: 'campaign_keysite_declaration', ...record, source_file: 'GEORGIA.CHC' }, named?.x ?? null, named?.z ?? null));
}
for (const entry of names) {
  features.push(feature({ record_kind: 'population_name', population_type: entry.type, name: entry.name, campaign_keysite: campaignByName.has(entry.name), source_file: 'POPNAME.DAT' }, entry.x, entry.z));
}
for (const entry of population.cities) {
  const template = population.templates[entry.templateIndex];
  const properties = { record_kind: 'city_template_placement', placement_index: entry.index, template_index: entry.templateIndex, template_type: template.typeName, template_object_count: template.objectCount, source_file: 'GEORGIA.BIN' };
  // A city entry is the origin of a multi-object EECH scenery template.  Its
  // origin can deliberately fall offshore (notably for port templates), so it
  // must not be advertised as a literal point on a contemporary basemap.
  features.push({
    type: 'Feature',
    properties: {
      ...properties,
      eech_world_x_metres: entry.x,
      eech_world_z_metres: entry.z,
      map_display: 'metadata_only',
      geometry_note: 'No WGS84 point is supplied: this is a multi-object EECH scenery-template origin, not the location of a building or facility.',
    },
    geometry: null,
  });
  sourceAnchorFeatures.push(sourceAnchorFeature(properties, entry.x, entry.z));
}
for (const entry of population.airfields) {
  const name = nearestNamedLocation(entry, names);
  const campaignKeysite = name ? campaignByName.get(name) : null;
  features.push(feature({ record_kind: 'airfield_placement', placement_index: entry.index, inferred_kind: airfieldKind(entry.shape), shape: entry.shape, map_label: name, campaign_keysite_type: campaignKeysite?.keysiteType ?? null, campaign_side: campaignKeysite?.side ?? null, source_file: 'GEORGIA.BIN' }, entry.x, entry.z));
}
for (const entry of population.sams) {
  features.push(feature({ record_kind: 'sam_aaa_placement', placement_index: entry.index, formation: 'LIGHT_SAM_AAA_GROUP', source_file: 'GEORGIA.BIN' }, entry.x, entry.z));
}

const output = {
  type: 'FeatureCollection',
  properties: {
    name: campaign.title,
    crs: 'WGS 84 (RFC 7946 GeoJSON)',
    source: 'Enemy Engaged: Comanche vs Hokum, Georgia map 3 / camp01',
    coordinate_method: 'EECH map-3 origin and Tacview metres-per-degree conversion',
    notes: 'Map-safe view. Campaign declarations BODRY and ZHARKY are mobile anchorage keysites with no fixed POPNAME coordinate. All 1,579 city-template entries are retained as metadata, but intentionally have null geometry: their source values are multi-object scenery-template origins, which are often offshore for port templates. See the source-anchors companion GeoJSON for those raw converted anchors, intended only for EECH source inspection.',
    counts: {
      campaign_keysite_declarations: campaign.records.length,
      population_names: names.length,
      city_template_placements: population.cities.length,
      airfield_placements: population.airfields.length,
      sam_aaa_placements: population.sams.length,
      total_features: features.length,
    },
  },
  features,
};

await writeFile(OUTPUT, `${JSON.stringify(output, null, 2)}\n`);
const sourceAnchorsOutput = {
  ...output,
  properties: {
    ...output.properties,
    name: `${campaign.title} — EECH source anchors`,
    notes: 'Source-inspection view. City-template geometry is the EECH template origin converted with the game map origin. It is not an accurate placement of individual scenery objects on a modern geographic basemap, and can be offshore by design.',
  },
  features: features.filter((item) => item.properties.record_kind !== 'city_template_placement').concat(sourceAnchorFeatures),
};
await writeFile(SOURCE_ANCHORS_OUTPUT, `${JSON.stringify(sourceAnchorsOutput, null, 2)}\n`);
console.log(`Wrote ${OUTPUT} and ${SOURCE_ANCHORS_OUTPUT} with ${features.length} features each.`);
