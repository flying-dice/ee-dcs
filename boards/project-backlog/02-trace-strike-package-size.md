---
column: backlog
labels: [bug, backend]
priority: med
updatedAt: 2026-09-21T16:06:45.000Z
---
# Trace STRIKE_PACKAGE_SIZE to the EECH source

`attack_waves.lua:56`:

```lua
local STRIKE_PACKAGE_SIZE = 2   -- a standard 2-ship strike flight (documented port constant)
```

Self-declared as a port constant with no C citation. The audit verified every other count in the
task pipeline against `highlevl.c:88-100` (`CREATE_CAS_TASK_COUNT` 2, `CREATE_BAI_TASK_COUNT` 2,
`CREATE_KEYSITE_STRIKE_TASK_COUNT` 3, `CREATE_OCA_STRIKE_TASK_COUNT` 1, `CREATE_SEAD_TASK_COUNT` 2,
`CREATE_OCA_SWEEP_TASK_COUNT` 2, `CREATE_TROOP_INSERTION_TASK_COUNT` 2) — this is the last one left
uncited.

Where to look: `suitable.c` (suitability matrix, ARMED_FIXED_WING for strike), `assign.c` (how a
group is picked for a task), `gp_dbase.c` (group database member counts), and the FORMCOMP.DAT
ordered-slot convention `ground_forces.lua` already follows for the ground OOB
(`faction.c:1579-1581`) — the air equivalent is the pattern to find.

If EECH genuinely yields 2 here, that is a fine outcome — but the comment must cite the C line that
produces it. If it genuinely cannot be reproduced in DCS, keep the closest faithful proxy and
document the divergence in the module header, per CLAUDE.md.

**Ledger coupling:** the value both consumes from the per-base reserve ledger and sizes the spawned
group (`attack_waves.lua:99`, `attack_waves.lua:326`, `attack_waves.lua:345-347`). Any change must
keep the consume count and spawned unit count identical, and the refund-on-failure path intact.

## Checklist

- [ ] Find what sizes a strike flight in the C (`suitable.c`, `assign.c`, `gp_dbase.c`, faction/FORMCOMP)
- [ ] Realign the value with a `file:line` citation, or port the lookup if the C sizes it from a DB row
- [ ] If irreproducible, document the exact divergence + why in the `attack_waves.lua` header
- [ ] Verify consume count == spawned unit count, refund-on-failure intact
- [ ] `lua-cargo build` 0 warnings + `check` no findings
- [ ] Remove item 3 from the CLAUDE.md misalignments list

## Comments

- **claude** (2026-09-21T16:06:45.000Z): Raised from the full port-fidelity audit. Confirmed by grepping every numeric constant in the generator path against `highlevl.c:88-100`; `attack_waves.lua:56` was the only survivor without a citation. Lower priority than card 01 because a 2-ship strike flight is at least plausible — but under the PRIME DIRECTIVE an uncited number is a latent bug regardless of whether it happens to be right.
