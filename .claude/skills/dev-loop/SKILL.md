---
name: dev-loop
description: Use whenever you change any Lua module under Scripts/dynamic-mission-test/ — the mandatory edit→build→check→inject→observe cycle for this EECH→DCS port, including the 0-warnings/no-findings gates, live re-injection, reading dcs.log, the verified-type-name DB guardrail, and the reserve-refund rule for spawner code.
---

# Dev loop: edit → build → check → inject → observe

The one true cycle for changing this port. Every change goes through it. Do not skip build or
check — they are gates, not suggestions.

## 0. Prerequisite: DCS Studio must be running

Build, static analysis (`check`), live eval/injection (`dcs_eval`), and live DB queries are **not**
shell commands — they are tools exposed by the **DCS Studio MCP server** at
`http://127.0.0.1:25570/mcp` (registered in `.mcp.json`). The DCS Studio desktop app must be
**running** for these tools to appear in a Claude session.

- **Detect absence:** if the build / check / `dcs_eval` / DB-query MCP tools are not present in your
  tool list, the app is not running (or the session predates its launch).
- **What to tell the user:** "Start the DCS Studio desktop app, then restart or reconnect this
  Claude session so the MCP tools register." Do **not** try to fake it.
- **Never** run `dcs-studio` from the shell to get help/output — that launches the full desktop app,
  it does not give you the tools.

## 1. Edit

Edit the modules under `Scripts/dynamic-mission-test/`. One system per module; each module header
names its EECH source file(s) — keep that header accurate (see the `eech-fidelity` skill).

## 2. Build (mandatory gate)

Run the DCS Studio **build** tool. It transpiles/bundles the 22 modules into
`dist/dynamic-mission-test.lua`.

- **Healthy output: 22 modules, 0 warnings.**
- Any warning is a stop-the-line failure. Fix it before proceeding — do not inject a warning build.

## 3. Check (mandatory gate)

Run the DCS Studio **check** (static analysis) tool over all files.

- **Healthy output: all files scanned, NO findings.**
- Any finding is a stop-the-line failure. Fix it (or, if it is a documented deliberate proxy, that
  belongs in `eech-fidelity` — check does not normally flag those). Do not inject with findings open.

The 0-warnings / no-findings discipline is absolute: both gates green after **every** change, no
exceptions, before you inject.

## 4. Inject into the live mission

With a mission running (see the `live-validation` skill for what that mission must be), inject via
the `dcs_eval` MCP tool:

```
net.dostring_in('server', 'dofile("C:/Users/jonat/DCSStudio/my-test-mod/dist/dynamic-mission-test.lua")')
```

**Re-injection is safe mid-session.** `campaign_state.lua` bumps a global `_DMT_GEN` (generation
counter) on every load; every scheduled closure captures `my_gen = cs.GENERATION` and self-cancels
(`return nil`) when `cs.GENERATION ~= my_gen`. So a hot re-inject supersedes the old timers instead
of double-running them. Caveat: this is **per-process only** — a `DCS_server.exe` restart resets all
in-memory state to OOB (there is no persistence yet).

## 5. Observe (dcs.log)

Mission-script logging goes through `env.info()` and lands in:

```
Saved Games/DCS/Logs/dcs.log
```

Read that file (or the log-reading MCP tool the DCS Studio server exposes, if present) to confirm
your change fired: init lines, scheduler ticks, reserve/strength/phase logs. What each system
should print and roughly when is the `live-validation` skill's observation checklist.

## Guardrails baked into this loop

### Verified type names only — query the live DB, never guess

Before you use **any** new unit type name or weapon CLSID in code, query the **live DCS DB** through
the DCS Studio bridge/MCP and confirm the exact string. The DB is reachable even at the main menu.
Guessing a type name silently produces `coalition.addGroup` failures or wrong loadouts. This is how
the verified statics (`.Ammunition depot`, `Fuel tank`, `Comms tower M`, `.Command Center`) and all
pylon CLSIDs were established — follow the same path for anything new.

### Spawners must refund the reserve pool on every failure branch

Every spawn passes through the finite per-side reserve (`supply.consume_side` on spawn,
`supply.recycle_side` on RTB/failure). If a spawn consumes reserve and then bails — most commonly
`coalition.addGroup` returning nil, or a "no friendly base" early return — you **must**
`recycle_side` the exact amount back before returning. A missed refund silently drains a pool
forever (this class of bug produced 3 HIGH findings in the Cluster A review). Audit **every** new
early-return and error branch in any spawner code path for the matching refund. Wrap `addGroup` in
`pcall` where a throw is possible and refund in the failure arm.
