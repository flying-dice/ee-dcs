---
column: backlog
labels: [bug, backend]
priority: med
updatedAt: 2026-09-21T16:06:45.000Z
---
# Replace the imap scan-range and threat proxies with per-unit DB values

> **Paths re-pointed 2026-09-21.** The Lua baseline was deleted; port modules below name their
> `packages/ee-mission/src/*.ts` counterparts. **Line numbers were taken against the Lua tree**
> and will not map exactly — locate by symbol, or read the original with
> `git show <pre-deletion-commit>:Scripts/ee-dcs/<module>.lua`. EECH C-source citations are
> unaffected.


`imap.ts:40-43` builds the AIR_DEFENCE and SURFACE_DEFENCE layers from flat uncited proxies:

```lua
local DEFAULT_AIR_SCAN_RANGE  = 25000 -- "proxy for FLOAT_TYPE_AIR_SCAN_RANGE on AA units"
local DEFAULT_SURF_SCAN_RANGE = 15000 -- "proxy for FLOAT_TYPE_SURFACE_SCAN_RANGE"
local AA_THREAT_VALUE         = 1.0   -- "FLOAT_TYPE_POTENTIAL_SURFACE_TO_AIR_THREAT proxy"
local SURF_THREAT_VALUE       = 1.0   -- "FLOAT_TYPE_POTENTIAL_SURFACE_TO_SURFACE_THREAT proxy"
```

In EECH these are **per unit type**, read from the vehicle database — not flat constants. Consumers
are `update_imap_surface_to_air_defence_level` and `update_imap_surface_to_surface_defence_level`
in `imaps.c` (the port already mirrors the documented `* 10` exaggeration).

**Effect:** a MANPAD and a long-range SAM project identical threat over an identical radius, so the
AIR_DEFENCE layer cannot distinguish a heavily defended airbase from a lightly defended one — which
is exactly what SEAD target selection and strike routing key off.

The port spawns its air defences from `base_defenses.ts` and `installations.ts` using DCS type
names from `config.C.types.ground` (aaa / sam / ewr / garrison). Map those to the EECH vehicle-DB
rows they stand in for and weight each deployed group by its own scan range and threat value.

**Guardrail (CLAUDE.md):** verified type names only — do not invent or guess a DCS type name or
CLSID; query the live DB via DCS Studio if a new one is needed.

## Checklist

- [ ] Find the real per-type scan-range / potential-threat fields in `vh_dbase.c`
- [ ] Read `imaps.c` for exactly how they are summed and normalised
- [ ] Map `config.C.types.ground` DCS types to their EECH vehicle-DB rows, citing `file:line` per value
- [ ] Weight each deployed AA/SAM group by its own values instead of the flat defaults
- [ ] Update the `imap.ts` header; drop "proxy" language for anything now traced
- [ ] `lua-cargo build` 0 warnings + `check` no findings
- [ ] Remove item 4 from the CLAUDE.md misalignments list

## Comments

- **claude** (2026-09-21T16:06:45.000Z): Raised from the full port-fidelity audit. **Depends on card 01** — both rewrite `imap.ts`, so land 01 first and rebase onto it rather than working them in parallel.
