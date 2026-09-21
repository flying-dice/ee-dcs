---
column: backlog
labels: [docs]
priority: low
updatedAt: 2026-09-21T16:06:45.000Z
---
# Sweep README and CHANGELOG for remaining stale claims

The 2026-09-21 audit corrected the stale doc claims it tripped over, but the sweep was
**opportunistic** — `README.md` is ~425 lines and was never audited end to end.

Already fixed in `CLAUDE.md` / `README.md`:

- main.lua's "legacy parallel supply/CAP/patrol layer" + `_G.game_loop` double-start (deleted in Cluster H)
- bundle module count 21 → 33
- dead "ANALYSIS section 4" pointer (now annotated with its git-history location)
- "imap layers held outside `S`" (they live on `S.imap` since Wave 1)
- "there is no production" (`supply.lua` has a production economy)
- README's heli_war row (deleted anti-armour/hunter-killer schedulers) and frontline row (Gabriel-graph)
- README's "Escalation phases" bullet — **fixed independently in the working tree** as
  "State-driven campaign tempo", which is why the audit's own version of that edit was dropped

Remaining work: verify **every** factual claim in README.md against the Lua in `Scripts/ee-dcs/`.
Highest-risk areas given the pattern above: any described mechanic a "Cluster" refactor may have
deleted, the per-module source table, the architecture section, and the multiplayer-status section.
`git log` the clusters to see what was removed. Also cross-check that the EECH file attributions in
the module table match each module's own header and the real paths under `E:\eech_source_code`.

Where a doc describes a deliberate divergence from EECH, make sure it says so **and** says why — per
CLAUDE.md an undocumented divergence is a latent bug, and a doc that hides one is worse than silence.

Depends on card 05 for the `CHANGELOG.md:13` dangling path and the spec-ID citations.

## Checklist

- [ ] Read README.md in full; verify each claim against the code
- [ ] Cross-check EECH file attributions in the module table
- [ ] Re-check the CLAUDE.md "Known open misalignments" list — remove items landed by cards 01–04
- [ ] Confirm every documented divergence states its reason
- [ ] Raise (do not fix) anything that turns out to be a code problem

## Comments

- **claude** (2026-09-21T16:06:45.000Z): Raised from the full port-fidelity audit. Low priority — these are prose errors, not behavioural ones — but the escalation-phases claim shows the risk concretely: the README was advertising a mechanic the port deliberately removed as invented, which is an active invitation for a future agent to "restore" it.
