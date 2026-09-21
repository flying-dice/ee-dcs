---
column: review
labels: [deployment, bug]
priority: high
agent: codex
live: false
updatedAt: 2026-09-21T21:53:00.000Z
---
# Review the GitHub Pages handoff

Review the other agent's Pages workflow against the compressed OSM delivery model and commit any fixes.

## Checklist

- [x] Inspect the workflow and its earlier corrective commit
- [x] Verify every theatre has a matching OSM asset in source and build output
- [x] Include root dependency-manifest changes in the deploy trigger
- [x] Update the web README's deployment destination
- [x] Build the campaign and web app, check types and OSM candidates
- [x] Commit the reviewed fixes

## Comments

- **codex** (2026-09-21T21:53:00.000Z): The previous guard only required one theatre and one gzip asset, allowing a newly added theatre to deploy with a missing OSM pair. The workflow now checks each pair before and after build. The README no longer claims Cloudflare is live. Campaign build, web build, type-check and OSM tests pass.
