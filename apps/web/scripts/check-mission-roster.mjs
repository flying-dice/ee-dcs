import assert from 'node:assert/strict';
import { createServer } from 'vite';

const vite = await createServer({ server: { middlewareMode: true }, appType: 'custom' });
try {
  const { buildMissionTable } = await vite.ssrLoadModule('/src/lib/miz.ts');
  const { distinctTypes } = await vite.ssrLoadModule('/src/lib/slots.ts');
  const { DEFAULT_UNIT_TYPES } = await vite.ssrLoadModule('/src/lib/units.ts');
  const mission = buildMissionTable([], { id: 'Caucasus' });
  const ids = (countries) => countries.map((entry) => entry.id);

  assert.deepEqual(mission.coalitions.blue, [80], 'BLU roster must contain only CJTF Blue');
  assert.deepEqual(mission.coalitions.red, [81], 'RED roster must contain only CJTF Red');
  assert.equal(mission.coalitions.neutrals.includes(80), false, 'CJTF Blue must not be neutral');
  assert.equal(mission.coalitions.neutrals.includes(81), false, 'CJTF Red must not be neutral');
  assert.equal(mission.coalitions.neutrals.includes(2), true, 'USA must remain neutral');
  assert.equal(mission.coalitions.neutrals.includes(0), true, 'Russia must remain neutral');
  assert.deepEqual(ids(mission.coalition.blue.country), [80], 'CJTF Blue table must be under BLU');
  assert.deepEqual(ids(mission.coalition.red.country), [81], 'CJTF Red table must be under RED');

  const withSlots = buildMissionTable([], { id: 'Caucasus' }, '', {
    blue: { id: 80, name: 'CJTF Blue', plane: { group: [] } },
    red: { id: 81, name: 'CJTF Red', helicopter: { group: [] } },
  });
  assert.deepEqual(ids(withSlots.coalition.blue.country), [80], 'BLU slots must use CJTF Blue');
  assert.deepEqual(ids(withSlots.coalition.red.country), [81], 'RED slots must use CJTF Red');
  const blankRed = Object.fromEntries(
    Object.keys(DEFAULT_UNIT_TYPES.red).map((role) => [role, '']),
  );
  const redFallbackTypes = distinctTypes('red', blankRed).map((entry) => entry.type);
  assert.equal(
    redFallbackTypes.includes(DEFAULT_UNIT_TYPES.red.striker),
    true,
    'blank RED slot types must use RED defaults',
  );
  assert.equal(
    redFallbackTypes.includes(DEFAULT_UNIT_TYPES.blue.striker),
    false,
    'blank RED slot types must not use BLUE defaults',
  );
  console.log('PASS mission coalition roster');
} finally {
  await vite.close();
}
