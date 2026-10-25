---
name: dcs-live-bridge
description: The working DCS bridge is JSON-RPC at 127.0.0.1:25570/rpc with string ids; it has no static-analysis check tool
metadata:
  type: reference
---

Live in-mission access is `POST http://127.0.0.1:25570/rpc` (`dcs-studio-mission`,
`x-dcs-env: mission`). Methods: `eval`, `console_read`, `repl_*`, `debug_*`, `dump_globals`,
`ping`. **JSON-RPC `id` must be a string** or it 400s.

**Why:** the repo previously described `http://127.0.0.1:25570/mcp` via `.mcp.json`; that URL
does not exist. The user deleted `.mcp.json` on 2026-09-22 and CLAUDE.md was corrected.

**How to apply:** use `eval` with plain curl for live probes — DCS must be running a loaded
mission, not the main menu. This bridge exposes **no static-analysis `check` tool**; that
belongs to the separate DCS Studio desktop MCP server and is usually absent. When it is,
substitute `npx biome check packages/ee-mission/src` and record `check` as **unrun, not
passed**. See [[live-evidence-beats-inspection]].
