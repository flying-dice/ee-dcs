/** @noSelfInFile */
/*
-- DCS FARP parking adapter.
--
-- The stock `FARP` static is a four-position heliport. DCS Mission Editor's
-- `me_exportToMiz.lua:895-944` serialises departures from it with
-- `TakeOffParking`, route-point `helipadId` + `linkUnit`, and per-aircraft
-- `parking`/`parking_id` values "1" through "4". An airdrome uses
-- `airdromeId` instead. Keeping this conversion here prevents individual
-- helicopter builders from accidentally stacking every aircraft at the
-- FARP object's origin.
*/

import * as cs from "./campaign_state";

export const FARP_PARKING_CAPACITY = 4;
const nextParkingByBase: Record<string, number> = {};

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

export function configureDeparture(
	baseName: string,
	base: Airbase,
	group: GroupData,
	departure: WaypointData,
): void {
	const baseId = base.getID();
	if (!isHelipad(baseName, base)) {
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
	departure.type = "TakeOffParking";
	departure.action = "From Parking Area";
	delete group.airdromeId;
	delete departure.airdromeId;
	departure.helipadId = baseId;
	departure.linkUnit = baseId;
	// DCS's own FARP exporter places the group, departure waypoint, and every
	// helicopter at the heliport origin before parking 1..4 is resolved by the
	// simulation. Leaving the builder's formation offsets here makes a dynamic
	// TakeOffParking group fail to materialise.
	const origin = base.getPosition().p;
	group.x = origin.x;
	group.y = origin.z;
	group.start_time = 0;
	departure.x = origin.x;
	departure.y = origin.z;
	departure.ETA = 0;
	let nextParking = nextParkingByBase[baseName] ?? 1;
	for (const unit of group.units) {
		const parking = tostring(nextParking);
		nextParking = (nextParking % FARP_PARKING_CAPACITY) + 1;
		unit.x = origin.x;
		unit.y = origin.z;
		unit.parking = parking;
		unit.parking_id = parking;
	}
	nextParkingByBase[baseName] = nextParking;
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
