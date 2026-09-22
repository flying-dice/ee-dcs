---
column: backlog
labels: [bug, backend]
priority: med
updatedAt: 2026-09-21T16:06:45.000Z
---
# Retire the last invented 200 km influence radius

> **Paths re-pointed 2026-09-21.** The Lua baseline was deleted; port modules below name their
> `packages/ee-mission/src/*.ts` counterparts. **Line numbers were taken against the Lua tree**
> and will not map exactly — locate by symbol, or read the original with
> `git show <pre-deletion-commit>:Scripts/ee-dcs/<module>.lua`. EECH C-source citations are
> unaffected.


`cas_bai_sead.ts:142-143` keeps a 200 km influence radius with this comment:

> "(no C source paints influence at a fixed metric radius), so it remains a designer-tunable
> proxy — kept at 200 km, deliberately not re-tuned in this cluster."

This is the last survivor of the invented fixed-km band. Two siblings already eliminated it:

- `frontline.ts` replaced the same threshold with parameter-free **Gabriel-graph base adjacency**,
  and its header records that spec 06 SECTOR-F16 **refuted** the fixed-km threshold as an EECH constant.
- `cas_bai_sead.ts:26` itself notes the invented `is_near_friendly` 200 km band was already replaced.

Also audit `troop.ts:103` (`SECTOR_RATIO_RADIUS = 200000`) — same smell, same origin, same pass.

EECH's influence maps are a **sector grid** (`SECTOR_SIDE_LENGTH`), so "influence within N metres"
is not an EECH concept at all — proximity is expressed in sector counts and grid neighbourhoods.
The faithful analogue is a topological / adjacency rule over base keysites (bases ARE the sectors in
this port — the convention `croute.ts` and `campaign_state.route_difficulty` document, `task.c:876`).
`frontline.echelon_of()` and `frontline.nearest_enemy()` already exist and may be the right primitives.

Do **not** swap one hand-picked number of kilometres for another. If a metric fallback is truly
unavoidable it must be DERIVED from a cited EECH quantity (e.g. sector side length x a cited
neighbourhood count), with the derivation documented.

**Critical guardrail (CLAUDE.md):** do NOT replace the single-shot exports with scheduler calls.
This module owns `cas_bai_sead.run_oca_sweep`, `cas_bai_sead.spawn_sead_against` and
`cas_bai_sead.spawn_bai_against`; the reaction chain depends on them staying single-shot.

## Checklist

- [ ] Read `imaps.c`, `highlevl.c` (create_cas/bai/sead_tasks), `ai_fline.c:125`/`:177`
- [ ] Replace the metric radius with a topological rule, following the `frontline.ts` precedent
- [ ] Audit `troop.ts:103` in the same pass — realign or cite it
- [ ] Confirm the single-shot exports are untouched
- [ ] `lua-cargo build` 0 warnings + `check` no findings
- [ ] Remove item 5 from the CLAUDE.md misalignments list

## Comments

- **claude** (2026-09-21T16:06:45.000Z): Raised from the full port-fidelity audit. This one changes CAS/BAI/SEAD target selection, so whoever takes it should state the expected behavioural effect and what to watch for in a live-validation soak (see the `live-validation` skill).
