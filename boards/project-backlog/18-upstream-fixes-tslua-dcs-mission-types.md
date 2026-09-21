---
column: backlog
labels: [bug, backend]
priority: high
updatedAt: 2026-09-21T23:30:00.000Z
---
# Upstream fixes for @flying-dice/tslua-dcs-mission-types

Three defects found while adopting the package (v0.33.0) in place of the hand-rolled `dcs.d.ts`.
All are **upstream** in `flying-dice/tslua-dcs`, which this org owns, so they are fixable at source
rather than worked around forever. The adoption itself is landed and green; these are the residue.

## 1. `coalition.side` is not a discriminated type — loses RED/BLUE safety (HIGH)

The port's central domain type was:

```ts
type Side = coalition.side.BLUE | coalition.side.RED;   // 268 usages
```

The package models it as a plain object of numbers:

```ts
side: { BLUE: number; RED: number; NEUTRAL: number }
```

so `Side` collapses to `number`, and **a wrong number now type-checks**. This is the most-used type
in the campaign — every task generator, every ledger operation, every reaction is keyed by side.
Losing the compile-time distinction is a real safety regression, even though behaviour is unchanged.

It could not be preserved downstream: the package declares `const coalition`, so the port cannot also
declare `namespace coalition`; and `Side = 1 | 2` would reject all ~213 `coalition.side.X` value
expressions. A branded type plus ~213 casts was rejected as worse than the disease.

**Fix upstream:** model these as a TS `enum`, or as literal-typed constants
(`readonly BLUE: 1; readonly RED: 2;` — DCS's actual values), so consumers get a real union. This
benefits every TSTL consumer, not just this repo.

`land.SurfaceType` has the same shape problem and had to become `number` at
`campaign_state.ts:394,401`. Worth fixing in the same pass — likely the same generator template.

## 2. F-10 menu callbacks omit `this: void` — hard compile break for TSTL (HIGH)

The package types menu callbacks as:

```ts
callback: (argument: T) => void        // no `this: void`
```

TSTL then assumes an implicit `self`, producing
`TSTL: Unable to convert function with no 'this' parameter` — 10 errors in `pilots.ts`. DCS invokes
`callback(argument)` with **no receiver**, so the hand-rolled declaration (`this: void`) was the more
correct one here.

Worked around locally with corrective overloads via `declare module`. **This makes the package
unusable for F-10 menus out of the box**, so it is worth fixing upstream promptly.

**Trap worth recording:** the first attempt omitted `@noSelf` on the augmenting interface and
silently emitted `missionCommands:addCommandForCoalition(` — a **colon call**, which at runtime
shifts every argument by one. `@noSelf` is **not inherited** by augmenting declarations. It is now
explicit with a comment. Nothing shipped; the bundle check caught it.

## 3. `l_Unit` / `l_StaticObject` do not extend `l_Object` (MEDIUM)

`l_Object` is not a supertype of the concrete classes, and it omits `getLife`/`getDesc`, which DCS
does expose on them. So a generic "DCS object" parameter cannot be typed as `l_Object` — attempting
it broke `pilots.ts:763`. The port declares its own structural `DcsObject` instead.

**Fix upstream:** have `l_Unit`, `l_StaticObject` (and anything else object-like) extend `l_Object`,
and move `getLife`/`getDesc` onto it where DCS provides them.

## Checklist

- [ ] Raise all three on `flying-dice/tslua-dcs`
- [ ] (1) model `coalition.side` and `land.SurfaceType` as enums or literal-typed constants
- [ ] (2) add `this: void` to menu callback signatures
- [ ] (3) make `l_Unit`/`l_StaticObject` extend `l_Object`
- [ ] On release, bump here and remove the local workarounds: the `declare module` overloads, the structural `DcsObject`, and restore `Side` to a real union
- [ ] Re-run the golden suite after the bump — a `Side` that is suddenly a union may surface latent mix-ups the `number` type was hiding

## Comments

- **claude** (2026-09-21T23:30:00.000Z): Raised while adopting the package (commit `9ea467d`). The adoption is landed, typechecks clean and the golden net is green, so none of this blocks — but item 1 means the campaign's most important type is currently `number`, and item 2 means anyone else adopting this package for F-10 menus hits a wall immediately. Both are cheap to fix at source. Item 2's `@noSelf` inheritance trap is recorded here deliberately: it produced a colon call that would have shifted every menu callback argument at runtime, and it was caught only because the emitted Lua was being diffed rather than trusted.
