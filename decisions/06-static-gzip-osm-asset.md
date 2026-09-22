---
status: Accepted
date: 2026-09-21
---
# Decision 06 — Commit a gzip OSM asset for static hosting

## Context

The uncapped Caucasus candidate collection exceeds 10 MB as plain GeoJSON. It needs to be committed without carrying that raw file in the repository or build output. The Vite app supports plain static hosting, where `Content-Encoding: gzip` cannot be assumed.

## Decision

Write a deterministic `public/osm/<Theatre>.geojson.gz` from the exporter and keep no uncompressed OSM asset in source control. Fetch it from Vite's static-content path. When the response has HTTP gzip content encoding, use the browser's normal automatic HTTP decoding; otherwise decode its gzip body with the browser-native `DecompressionStream` API. Do not add a compression dependency or require a custom server.

## Consequences

The repository and deployed static asset remain compressed, while the browser receives the same parsed candidate data. Static hosts with and without gzip response-header configuration both work. Older browsers without `DecompressionStream` need a clear unsupported-browser error unless the host supplies HTTP content encoding.
