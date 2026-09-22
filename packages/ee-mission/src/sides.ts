/** @noSelfInFile */
/*
-- sides.ts
-- Validated boundary between the DCS `coalition.side` table and the campaign's
-- `Side` domain.
--
-- WHY THIS MODULE EXISTS
--   `@flying-dice/tslua-dcs-mission-types` declares the side table as
--     side: { BLUE: number; NEUTRAL: number; RED: number }
--   (dist/exports/coalition.export.d.ts:30-34), i.e. it widens the three
--   constants to plain `number`. Consuming `coalition.side.RED` directly would
--   therefore make every `Side` parameter and every `Record<Side, ...>` accept
--   any number at all — neutral, an Object.Category id, a group id, anything.
--   That is an upstream defect (tracked on board card 18); until the package
--   exposes literal constants or an enum, the campaign keeps its own closed
--   RED/BLUE domain and narrows here, ONCE, instead of casting at ~213 sites.
--   Module augmentation cannot fix it in place: redeclaring `side` with literal
--   types inside a `declare module` merge is a duplicate-property conflict.
--
-- PROVENANCE OF THE LITERALS
--   DCS World mission scripting defines coalition.side.NEUTRAL = 0,
--   coalition.side.RED = 1, coalition.side.BLUE = 2 (DCS
--   Scripts/MissionScripting / the ED scripting engine enumeration; the same
--   values the mission-editor .miz files and `coalition.getGroups(side)` use,
--   and the values both offline harnesses stub:
--   packages/ee-mission/test/core-parity.lua:32 and
--   packages/ee-mission/test/campaign-smoke.lua:125).
--
-- THE RUNTIME VALUES ARE STILL THE ENGINE'S
--   RED/BLUE/NEUTRAL below are read FROM `coalition.side`, not hard-coded, so
--   the campaign always sends DCS its own numbers. The literal types are then
--   verified against the engine at load time by assertSideValues(): if DCS ever
--   renumbers the coalitions the campaign fails loudly at init rather than
--   silently mislabelling every group it spawns.
*/

/** Value of `coalition.side.RED`. See PROVENANCE above. */
const RED_VALUE = 1;
/** Value of `coalition.side.BLUE`. See PROVENANCE above. */
const BLUE_VALUE = 2;
/** Value of `coalition.side.NEUTRAL`. See PROVENANCE above. */
const NEUTRAL_VALUE = 0;

/**
 * A combatant coalition: RED or BLUE.
 *
 * Deliberately closed, and deliberately excludes NEUTRAL — the campaign's
 * force pools, ownership maps, task sides and `Record<Side, ...>` tables only
 * ever model the two combatants, exactly as the hand-rolled `dcs.d.ts`
 * declarations did before the types package was adopted.
 */
export type Side = typeof RED_VALUE | typeof BLUE_VALUE;

/** The non-combatant coalition. Not a {@link Side}; see {@link AnyCoalition}. */
export type Neutral = typeof NEUTRAL_VALUE;

/**
 * Any value `coalition.*` accepts, including NEUTRAL.
 *
 * Used only where the campaign enumerates every coalition to sweep the DCS
 * object tables (`coalition.getGroups` / `getStaticObjects` / `getAirbases`),
 * which is a DCS-API concern rather than a campaign-side one.
 */
export type AnyCoalition = Side | Neutral;

// The one narrowing cast in the campaign. Everything downstream is typed.
export const RED = coalition.side.RED as typeof RED_VALUE;
export const BLUE = coalition.side.BLUE as typeof BLUE_VALUE;
export const NEUTRAL = coalition.side.NEUTRAL as Neutral;

/**
 * Fails loudly if the engine's side numbers are not what {@link Side} claims.
 *
 * This is what makes the casts above a validated boundary rather than a blind
 * assertion. Runs at module load, so it runs before any campaign code can use
 * a side value.
 */
function assertSideValue(name: string, engine: number, expected: number): void {
	if (engine === expected) return;
	error(
		`ee-dcs: coalition.side.${name} is ${tostring(engine)}, but the campaign's` +
			` Side type is built on ${expected}. The DCS coalition numbering has` +
			" changed; src/sides.ts must be updated before the campaign can run.",
	);
}

assertSideValue("RED", coalition.side.RED, RED_VALUE);
assertSideValue("BLUE", coalition.side.BLUE, BLUE_VALUE);
assertSideValue("NEUTRAL", coalition.side.NEUTRAL, NEUTRAL_VALUE);
