import assert from 'node:assert/strict';
import { createServer } from 'vite';
import JSZip from 'jszip';

const vite = await createServer({ server: { middlewareMode: true }, appType: 'custom' });
try {
  const { buildMiz } = await vite.ssrLoadModule('/src/lib/miz.ts');
  const { TERRAINS } = await vite.ssrLoadModule('/src/lib/terrains.ts');
  const sourceTerrain = TERRAINS.find((terrain) => terrain.id === 'Caucasus') ?? TERRAINS[0];
  assert.ok(sourceTerrain, 'a baked terrain is required for the FARP archive check');
  const point = sourceTerrain.center;
  const terrain = {
    ...sourceTerrain,
    airbases: [{
      name: 'Slot Test Airbase',
      category: 'AIRDROME',
      airdromeId: 1,
      latlon: point,
      parking: [{ termIndex: 1, termType: 68, toAc: true, x: 100, y: 200, alt: 0 }],
    }],
  };
  const keysite = (type, side, label, name, latlon = point) => ({
    id: `${type}:${label}`,
    type,
    side,
    latlon,
    label,
    radiusM: 1200,
    name,
    locationTied: false,
  });
  const keysites = [
    keysite('airbase', 'blue', 'slot-test', 'Slot Test Airbase'),
    keysite('farp', 'blue', 'blue-pad', 'Blue pad', { lat: point.lat + 0.01, lon: point.lon + 0.01 }),
    keysite('farp', 'red', 'red-pad', 'Red pad', { lat: point.lat - 0.01, lon: point.lon - 0.01 }),
  ];
  const archive = await JSZip.loadAsync(await (await buildMiz(keysites, terrain, {
    bakeCampaign: false,
  })).arrayBuffer());
  const mission = await archive.file('mission').async('string');
  const warehouses = await archive.file('warehouses').async('string');
  const farpNames = ['FARP-farp_blue-pad', 'FARP-farp_red-pad'];
  const farpUnitIds = [];

  for (const name of farpNames) {
    assert.match(mission, new RegExp(`\\["name"\\] = "${name}",`), `${name} must be a static unit`);
    const unit = mission.match(new RegExp(`\\["unitId"\\] = (\\d+),(?:(?!\\["unitId"\\])[\\s\\S])*?\\["name"\\] = "${name}",`));
    assert.ok(unit, `${name} must have a static unit id`);
    farpUnitIds.push(Number(unit[1]));
  }
  assert.equal((mission.match(/\["shape_name"\] = "FARPS",/g) ?? []).length, 2, 'both FARPs use stock FARPS shape');
  assert.equal((mission.match(/\["category"\] = "Heliports",/g) ?? []).length, 2, 'both FARPs use Heliports category');
  assert.equal((mission.match(/\["heliport_frequency"\] = "127\.5",/g) ?? []).length, 2, 'both FARPs use 127.5 MHz');
  assert.equal((mission.match(/\["heliport_modulation"\] = 0,/g) ?? []).length, 2, 'both FARPs use AM modulation');
  assert.equal((mission.match(/\["heliport_callsign_id"\] = 1,/g) ?? []).length, 2, 'both FARPs use callsign 1');
  assert.match(mission, /\["coalition"\] =\s*\{[\s\S]*?\["blue"\] =\s*\{[\s\S]*?FARP-farp_blue-pad/, 'blue FARP belongs to BLUE');
  assert.match(mission, /\["coalition"\] =\s*\{[\s\S]*?\["red"\] =\s*\{[\s\S]*?FARP-farp_red-pad/, 'red FARP belongs to RED');
  const ids = (key) => [...mission.matchAll(new RegExp(`\\["${key}"\\] = (\\d+),`, 'g'))].map((match) => Number(match[1]));
  for (const key of ['groupId', 'unitId']) {
    const values = ids(key);
    assert.equal(values.length, new Set(values).size, `${key}s must be unique with Client slots`);
  }
  assert.match(mission, /\["skill"\] = "Client",/, 'fixture must contain a baked Client slot');
  assert.equal((warehouses.match(/\["unlimitedAircrafts"\] = true,/g) ?? []).length, 2, 'each FARP has unlimited aircraft supply');
  assert.equal((warehouses.match(/\["coalition"\] = "blue",/g) ?? []).length, 1, 'blue FARP warehouse is BLUE');
  assert.equal((warehouses.match(/\["coalition"\] = "red",/g) ?? []).length, 1, 'red FARP warehouse is RED');
  for (const unitId of farpUnitIds) {
    assert.match(warehouses, new RegExp(`\\[${unitId}\\] =\\s*\\{`), `FARP warehouse must use static unit id ${unitId}`);
  }
  for (const sites of [[], [keysites[0]]]) {
    const noFarpArchive = await JSZip.loadAsync(await (await buildMiz(sites, terrain, {
      bakeCampaign: false,
      bakeSlots: false,
    })).arrayBuffer());
    const noFarpMission = await noFarpArchive.file('mission').async('string');
    const noFarpWarehouses = await noFarpArchive.file('warehouses').async('string');
    assert.doesNotMatch(noFarpMission, /\["shape_name"\] = "FARPS",/, 'empty and non-FARP missions add no FARP static');
    assert.match(noFarpWarehouses, /\["warehouses"\] = \{\},/, 'empty and non-FARP missions keep warehouses empty');
  }
  console.log('PASS baked stock FARPs and warehouses');
} finally {
  await vite.close();
}
