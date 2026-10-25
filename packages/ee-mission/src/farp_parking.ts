/** @noSelfInFile */
/*
-- DCS FARP parking adapter.
--
-- The stock `FARP` static is a four-position heliport. DCS Mission Editor's
-- `me_exportToMiz.lua:895-944` serialises departures from it with
-- `TakeOffParking`, route-point `helipadId` + `linkUnit`, and per-aircraft
-- `parking`/`parking_id` values. An airdrome uses `airdromeId` instead.
-- Keeping this conversion here prevents individual helicopter builders from
-- accidentally stacking every aircraft at the FARP object's origin.
--
-- NOT an EECH behaviour: EECH has no parking model (keysite aircraft are a
-- count, `assign.c:259 get_suitable_registered_group`). Everything below is a
-- DCS-representation fact, read from the live Airbase object. No campaign
-- constant is set here.
--
-- TWO SEPARATE JOBS, deliberately kept apart (epic #17 P2):
--   1. STAND SELECTION — which physical `Term_Index` each aircraft gets. Read
--      from the live terminal set and leased through `aircraft_lifecycle`, so
--      the lease is owned by the allocation and rolls back with it.
--   2. DEPARTURE SERIALISATION — the helipadId/linkUnit/origin/hot-start
--      encoding below, which is unchanged and separately proven.
--
-- MEASURED (docs/bots/LIVE-PROBE-2026-09-22.md, findings 2-4):
--   * `Term_Index` on a stock four-pad FARP is 0,1,2,3 and the emitted
--     `parking` value maps DIRECTLY onto it. The previous "1".."4" modulo
--     counter therefore addressed a non-existent stand once every four
--     aircraft and could never use pad 0. The ME exporter's "1 through 4" is
--     1-based EDITOR naming, not the runtime index.
--   * `getParking(true)` does NOT reflect occupancy (4-of-4 "available" with
--     three pads flagged taken), so occupancy comes from per-terminal `TO_AC`.
--   * A departed aircraft keeps `TO_AC=true` while airborne, so a stand is
--     never freed because its aircraft took off.
--
-- UNKNOWN IS NOT EMPTY. When the live terminal set cannot be read — no
-- `getParking`, a query that raises, or terminals without a numeric
-- `Term_Index` — capacity is UNKNOWN. It is not treated as zero (which would
-- block every departure from a base DCS simply would not describe) and not as
-- unlimited. The adapter falls back to the previously shipped per-base
-- rotation, takes no lease, and records a debug diagnostic once per base.
-- Stand leasing applies only where there is real terminal data to lease
-- against.
*/

import * as aircraft from "./aircraft_lifecycle";
import * as cs from "./campaign_state";

/**
 * Stock DCS FARP heliport terminal count. Used only by the no-terminal-data
 * fallback below and by the group-too-large guard; the leasing path never
 * assumes it and reads the real terminal set instead.
 */
export const FARP_PARKING_CAPACITY = 4;
const nextParkingByBase: Record<string, number> = {};
const unknownTerminalsWarned: Record<string, boolean> = {};

function isHelipad(baseName: string, base: Airbase): boolean {
	const kind = cs.S.base_kind[baseName];
	if (kind !== "farp" && kind !== "fob") return false;
	const [read, description] = pcall(() => base.getDesc());
	if (read && description?.category !== undefined)
		return description.category === Airbase.Category.HELIPAD;
	// Generated forward FARPs are always stock heliports. Real FOB airfields
	// retain airdrome semantics when DCS reports their category.
	return kind === "farp";
}

/**
 * The live terminal set, or undefined when DCS will not describe it. `available=false` is
 * deliberate: `getParking(true)` was measured NOT to reflect occupancy, so the full set is read
 * and occupancy is taken from each terminal's own `TO_AC`.
 */
function readTerminals(
	baseName: string,
	base: Airbase,
): aircraft.TerminalSpot[] | undefined {
	const [methodOk, hasMethod] = pcall(() => base.getParking !== undefined);
	if (!methodOk || !hasMethod)
		return unknownTerminals(baseName, "no getParking");
	const [queryOk, spots] = pcall(() => base.getParking(false));
	if (!queryOk || spots === undefined)
		return unknownTerminals(baseName, "parking query failed");
	const terminals: aircraft.TerminalSpot[] = [];
	for (const spot of spots) {
		// A terminal we cannot index is a terminal we cannot address in `parking`. One bad row
		// makes the whole set unusable: guessing the missing index is exactly the invented value
		// this must not produce.
		if (typeof spot.Term_Index !== "number")
			return unknownTerminals(
				baseName,
				"terminal without a numeric Term_Index",
			);
		terminals.push({ index: spot.Term_Index, occupied: spot.TO_AC === true });
	}
	if (terminals.length === 0)
		return unknownTerminals(baseName, "no terminals reported");
	terminals.sort((left, right) => left.index - right.index);
	return terminals;
}

function unknownTerminals(baseName: string, why: string): undefined {
	if (!unknownTerminalsWarned[baseName]) {
		unknownTerminalsWarned[baseName] = true;
		cs.dbg(
			"parking",
			"%s reports no usable terminal data (%s) — stand capacity UNKNOWN, using the fallback rotation and taking no stand lease",
			baseName,
			why,
		);
	}
	return undefined;
}

/**
 * Picks one distinct physical stand per aircraft and leases it, or returns undefined when the
 * live terminal set cannot be read. Throws when the base has real terminal data but cannot seat
 * the whole group: the caller must fail the launch rather than stack aircraft onto one pad.
 */
function selectStands(
	baseName: string,
	base: Airbase,
	group: GroupData,
): string[] | undefined {
	const terminals = readTerminals(baseName, base);
	if (terminals === undefined) return undefined;
	const unitNames: string[] = [];
	for (const unit of group.units) unitNames.push(unit.name);
	const claimed = aircraft.reserve_stands(
		baseName,
		group.name,
		unitNames,
		terminals,
	);
	if (claimed === undefined) {
		let occupied = 0;
		for (const terminal of terminals) if (terminal.occupied) occupied += 1;
		// Raised BEFORE any coalition.addGroup for this group (every caller configures the
		// departure first), so nothing is spawned and nothing is half-created. The builder fails,
		// task_board's pcall reverses the allocation — ledger debit, keysite slot and any stand
		// this allocation already took — and the task goes back to UNASSIGNED for the existing
		// assignment pass to retry. No new retry timer, no new cadence.
		error(
			string.format(
				"%s has no free parking stand for group %s: %d requested, %d terminals, %d occupied (TO_AC), %d leased",
				baseName,
				group.name,
				group.units.length,
				terminals.length,
				occupied,
				aircraft.leased_stands(baseName).length,
			),
		);
	}
	const parking: string[] = [];
	for (const index of claimed) parking.push(tostring(index));
	return parking;
}

/** Fallback rotation, used only when the live terminal set is unknown. Previous behaviour. */
function rotateStands(baseName: string, group: GroupData): string[] {
	let next = nextParkingByBase[baseName] ?? 1;
	const parking: string[] = [];
	for (const _unit of group.units) {
		parking.push(tostring(next));
		next = (next % FARP_PARKING_CAPACITY) + 1;
	}
	nextParkingByBase[baseName] = next;
	return parking;
}

export function configureDeparture(
	baseName: string,
	base: Airbase,
	group: GroupData,
	departure: WaypointData,
): void {
	const baseId = base.getID();
	if (!isHelipad(baseName, base)) {
		// Ordinary airfields and real FOB airdromes: DCS resolves the stand itself from
		// airdromeId, so no `parking`/`parking_id` is emitted and no stand is leased. Emitting a
		// terminal index here would be a guess about parking data this adapter does not own.
		delete group.helipadId;
		delete group.linkUnit;
		delete departure.helipadId;
		delete departure.linkUnit;
		group.airdromeId = baseId;
		departure.airdromeId = baseId;
		return;
	}
	if (group.units.length > FARP_PARKING_CAPACITY)
		error(
			string.format(
				"FARP %s has %d parking positions but group %s contains %d helicopters",
				baseName,
				FARP_PARKING_CAPACITY,
				group.name,
				group.units.length,
			),
		);
	// Stand selection first: it can fail, and it must fail before anything is serialised.
	const parking =
		selectStands(baseName, base, group) ?? rotateStands(baseName, group);
	// Preserve the builder's hot/cold choice. The ME exporter supplies cold
	// defaults, but campaign builders deliberately request hot ramp starts.
	departure.action =
		departure.type === "TakeOffParkingHot"
			? "From Parking Area Hot"
			: "From Parking Area";
	delete group.airdromeId;
	delete departure.airdromeId;
	departure.helipadId = baseId;
	departure.linkUnit = baseId;
	// DCS's own FARP exporter places the group, departure waypoint, and every
	// helicopter at the heliport origin before the stand is resolved by the
	// simulation. Leaving the builder's formation offsets here makes a dynamic
	// TakeOffParking group fail to materialise.
	const origin = base.getPosition().p;
	group.x = origin.x;
	group.y = origin.z;
	group.start_time = 0;
	departure.x = origin.x;
	departure.y = origin.z;
	departure.ETA = 0;
	for (let index = 0; index < group.units.length; index += 1) {
		const unit = group.units[index];
		unit.x = origin.x;
		unit.y = origin.z;
		unit.parking = parking[index];
		unit.parking_id = parking[index];
	}
}

export function configureLanding(
	baseName: string,
	base: Airbase,
	landing: WaypointData,
): void {
	const baseId = base.getID();
	if (isHelipad(baseName, base)) {
		delete landing.airdromeId;
		landing.helipadId = baseId;
		landing.linkUnit = baseId;
	} else {
		delete landing.helipadId;
		delete landing.linkUnit;
		landing.airdromeId = baseId;
	}
}
