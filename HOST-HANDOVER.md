# Preservation checkpoint — 25 October 2026

This branch preserves the previously uncommitted working tree for host transfer.
It is NOT accepted, merge-ready or a new task to continue the TypeScript port.
The active M5 native programme is in flying-dice/eech_source_code, integration
branch claude/eech-campaign-native-spike-tjkj6g. D1 is accepted there at a7934aa7.
Confluence11534337 and14548994 define the current migration scope.

One independent handover review found:
- Primary fixed-wing strike, SEAD strike and OCA sweep do not call lifecycle.track
  (attack_waves.ts around275, cas_bai_sead.ts around510/818); only escorts track.
  commit_allocation drops empty attempt lists, so deferred primary-flight failure
  cannot refund/relist. The older caller-map claim that all board paths use the
  contract is not valid for those paths.
- unitIsPlayer treats a failed player-name query as non-player; retirement can
  destroy that aircraft. A conservative unknown result and test are still needed.
- Existing open work: fresh-mission P5 witness, CRASH regeneration defect and
  deferred economy asymmetries. Earlier status text is historical, not acceptance.

Validation on this checkpoint: npm run test --workspace ee-mission passed build,
27 core checks, diagnostics, lifecycle legs, 310/2100-second campaign smoke and
clearance checks. Biome exited0 with18warnings/50infos (existing recorded counts).
git diff --check finds generated dist/ee-dcs.lua whitespace; the generated output
is preserved as produced by the build. DCS Studio check and live witness unrun.

User explicitly requested pushing Git work for transfer. This checkpoint keeps
the unfinished behaviour visible rather than changing unrelated campaign code
during a handover. Do not merge it without resolving the listed acceptance gaps.
No credentials are included. Deleted .mcp.json is an existing documented change,
not a new authentication change.
