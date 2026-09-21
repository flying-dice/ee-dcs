---
column: review
labels: [backend, frontend, perf]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:48:00.000Z
---
# Commit the OSM candidate asset compressed

Store the large Caucasus candidate export as gzip in the web app's static-content directory, and use browser-native decompression so plain static hosting still works. See [Decision 06](../../decisions/06-static-gzip-osm-asset.md).

## Checklist

- [x] Generate deterministic gzip output and remove the uncompressed source asset
- [x] Load the static gzip asset in the browser, including the HTTP-encoded case
- [x] Verify round-trip, production static serving, type checks and build
- [x] Commit the compressed asset and dependent pipeline changes safely

## Comments

- **codex** (2026-09-21T21:39:00.000Z): `apps/web/src/osm/Caucasus.geojson:1` is about 10 MB as an untracked source asset. `apps/web/src/lib/osm.ts:9` imports it through Vite's asset pipeline. The app also targets hosts without configurable HTTP response headers, so native browser decompression of a static `.geojson.gz` file is needed for portability.
- **codex** (2026-09-21T21:48:00.000Z): The production build serves the 350,388-byte gzip asset with HTTP gzip encoding; browser-compatible decoding returns all 10,533 candidates. The plain 10 MB source was removed. Type-check, build and OSM policy tests pass. See [active-area](21-active-area-osm-pruning.md) and [site-footprint](22-site-footprint-centres.md) follow-ups.
