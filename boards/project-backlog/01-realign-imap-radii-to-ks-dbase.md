---
column: backlog
labels: [bug, backend]
priority: high
updatedAt: 2026-09-21T16:06:45.000Z
---
# Realign imap radii to the per-keysite ks_dbase.c values

`imap.lua:36-37` uses flat, uncited radii and its header claims they are "not per-keysite in our
approximation". That is false — they are per-sub-type literals in the EECH keysite_database.

| | port (`imap.lua:36-37`) | EECH (`ks_dbase.c`) |
|---|---|---|
| air coverage (airbase) | 150 km | **400 km** (`ks_dbase.c:104`) |
| importance (airbase) | 100 km | **80 km** (`ks_dbase.c:103`) |
| FARP | same flat values | 100 km / 40 km |
| factory | same flat values | **0 km** / 40 km |
| military base | same flat values | **0 km** / 30 km |

Air coverage is 2.7x too tight and flat across types EECH differentiates sharply. Consumers are
`imaps.c:486` (importance) and `imaps.c:642` (air coverage). The `BASE_DISTANCE` and `IMPORTANCE`
layers feed `keysite.rate_*`, which drives target selection for **every** `create_*_tasks`
generator — so this skews the whole campaign toward near-base targets.

`installations.lua:72` already transcribes each kind's `ks_dbase.c` row, but only the **boolean**
columns. Extend it with the numeric ones and have `imap.lua` read per-kind.

Violates the CLAUDE.md PRIME DIRECTIVE (every constant must cite a C source line). See the
"Known open misalignments (audit 2026-09-21)" section in `CLAUDE.md`, item 1.

## Checklist

- [ ] Read the remaining `ks_dbase.c` rows (OIL_REFINERY, PORT, POWER_STATION, RADIO_TRANSMITTER) and cite each line
- [ ] Extend `installations.lua:72` FLAGS rows with `importance`, `importance_radius`, `air_coverage_radius`, `recon_distance`
- [ ] Expose via `installations.flags_for_kind`; cover the `airbase` / `farp` kinds set by `farps.lua`
- [ ] Rewrite `imap.lua` to read per-kind — a kind with air_coverage_radius 0 must contribute NOTHING, not a default
- [ ] Delete the false "not per-keysite" claim from the `imap.lua` header; cite `ks_dbase.c` / `imaps.c`
- [ ] Fix the stale `keysite.lua:269` claim ("all port keysites are airbases, equal importance 1.0")
- [ ] Re-check `designate_objectives` against `setup.c:224-262` — follow the C, do not invent a weighting
- [ ] `lua-cargo build` 0 warnings + `check` no findings
- [ ] Remove items 1 and 2 from the CLAUDE.md misalignments list

## Comments

- **claude** (2026-09-21T16:06:45.000Z): Raised from the full port-fidelity audit. Verified against `E:\eech_source_code\aphavoc\source\entity\special\keysite\ks_dbase.c:103-104` (airbase row) by reading the keysite_database initialiser directly. This is the highest-impact find of the audit: unlike the other items it is not a "proxy for a DCS limit" — the real values are sitting in a table the port already transcribes for its boolean columns, so there is no structural reason for the divergence.
