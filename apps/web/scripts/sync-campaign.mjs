// Copy the built EECH campaign bundle into the app so Vite can `?raw`-embed it in
// generated .miz files. Source of truth is the repo-root build output
// (dist/ee-dcs.lua from `npm run build --workspace ee-mission`); this mirrors the
// current bytes into src/generated/ where the frontend imports them.
//
// Runs automatically before dev/build/check (npm pre* hooks) and can be invoked
// directly with `npm run sync:campaign`. The copy is git-ignored — rebuild the
// campaign, then dev/build, and the freshest bundle ships with every .miz.

import { copyFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(here, '../../../dist/ee-dcs.lua');
const DEST = resolve(here, '../src/generated/campaign-bundle.lua');

if (!existsSync(SRC)) {
  console.error(
    `[sync-campaign] campaign bundle not found at:\n  ${SRC}\n` +
      `Build it first (npm run build --workspace ee-mission) so the .miz can ship the Lua.`,
  );
  process.exit(1);
}

mkdirSync(dirname(DEST), { recursive: true });
copyFileSync(SRC, DEST);
const kb = (statSync(DEST).size / 1024).toFixed(0);
console.log(`[sync-campaign] campaign bundle → src/generated/campaign-bundle.lua (${kb} KB)`);
