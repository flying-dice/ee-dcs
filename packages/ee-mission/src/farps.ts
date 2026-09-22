/** @noSelfInFile */
/*
-- farps.lua — base-role classification + forward FARP network
-- EECH source:
--   ks_dbase.c: AIRBASE (air_force_capacity LARGE, fixed-wing + heli, requires_cap TRUE, requires_
--     barcap FALSE); FARP (air_force_capacity SMALL, HELICOPTERS ONLY).
--   popread.c:1601-1664,1981-2019: airfields with fixed-wing runway routes are AIRBASEs, the rest are
--     helicopter sites; FARP keysites are placed at forward FARP objects. EECH warzones field only a
--     handful of fixed-wing airbases plus a dense field of heli-only bases and forward FARPs.
--
-- Two layers, both EECH-faithful:
--  1) CLASSIFY the DCS airfields (PREDICTABLE structure): a fixed number per side (the REAR fields)
--     run as fixed-wing AIRBASEs; the rest run as heli-only FOBs ("FARP only behaviour").
--  2) Place a FORWARD FARP network (RANDOMNESS/variety): extra heli-only forward bases ahead of the
--     line, jittered in position and count so each campaign's rotary staging differs.
-- Enforcement is via the supply ledger: airbase = fixed-wing + heli; FOB/FARP = helicopters only. So
-- fixed-wing (OCA / keysite strike / SEAD) launches ONLY from the few airbases, while the rotary war
-- (CAS/BAI/insertion) flies from the whole FOB + FARP network — an EECH helicopter-primary front.
*/

import * as cs from "./campaign_state";
import type { Side } from "./campaign_types";
import * as config from "./config";
import { BLUE, RED } from "./sides";
import * as zones from "./zones";

type LogFunction = (this: void, message: string) => void;
interface RatedField {
	name: string;
	distance: number;
}
interface FieldOwner {
	name: string;
	owner: Side;
}

const S = cs.S;
const SIDES: Side[] = [BLUE, RED];
const FIXED_WING_PER_SIDE = config.C.theatre.fixed_wing_per_side;
const FRONT_DIST = config.C.theatre.farp_front_dist;
// DCS adapter placement envelope in metres; EECH uses authored FARP objects rather than offsets.
const FARP_FORWARD_MIN_METRES = 18000;
const FARP_FORWARD_MAX_METRES = 40000;
const FARP_LATERAL_JITTER_METRES = 22000;
const FARP_PLACEMENT_CHANCE_PERCENT = 70;
const RANDOM_PERCENT_MAX = 100;
// DCS adapter cadence; EECH activation is entity-driven, so poll every two minutes.
const ACTIVATION_POLL_SECONDS = 120;
// Deterministic seed mixing constants for milliseconds and generation separation.
const MILLISECONDS_PER_SECOND = 1000;
const GENERATION_SEED_PRIME = 7919;
// Preserve at least one fixed-wing field and no more than one third of available fields.
const FIXED_WING_FIELD_DIVISOR = 3;
const COUNTRY = config.C.countries;
// Mission Editor-authored stock FARP defaults, verified from a DCS 2.9 mission:
// type=FARP, shape_name=FARPS, 127.5 MHz AM and callsign id 1 (London).
const STOCK_FARP_FREQUENCY_MHZ = "127.5";
const STOCK_FARP_AM_MODULATION = 0;
const STOCK_FARP_CALLSIGN_ID = 1;

function ensurePhysicalFarp(
	name: string,
	owner: Side,
	position: { x: number; z: number },
): boolean {
	const [airbaseRead, airbase] = pcall(() => Airbase.getByName(name));
	if (airbaseRead && airbase !== undefined) return false;
	const [staticRead, staticObject] = pcall(() => StaticObject.getByName(name));
	if (staticRead && staticObject?.isExist()) return false;

	const farpStatic = config.C.statics.farp;
	coalition.addStaticObject(COUNTRY[owner], {
		heading: 0,
		type: farpStatic.type,
		shape_name: farpStatic.shape_name,
		category: farpStatic.category,
		name,
		x: position.x,
		y: position.z,
		dead: false,
		heliport_frequency: STOCK_FARP_FREQUENCY_MHZ,
		heliport_modulation: STOCK_FARP_AM_MODULATION,
		heliport_callsign_id: STOCK_FARP_CALLSIGN_ID,
	});
	return true;
}

function fixedWingCount(sideFieldCount: number): number {
	return math.max(
		1,
		math.min(
			FIXED_WING_PER_SIDE,
			math.floor(sideFieldCount / FIXED_WING_FIELD_DIVISOR),
		),
	);
}

function nearestEnemy(
	base: string,
	side: Side,
): LuaMultiReturn<[string | undefined, number]> {
	const basePos = S.base_pos[base];
	const enemy = cs.ENEMY[side];
	if (basePos === undefined || enemy === undefined)
		return $multi(undefined, math.huge);
	let best: string | undefined;
	let bestDistance = math.huge;
	for (const [name, owner] of pairs(S.base_owner)) {
		const enemyPos = S.base_pos[name];
		if (owner === enemy && enemyPos !== undefined) {
			const distance = cs.dist2d(basePos.x, basePos.z, enemyPos.x, enemyPos.z);
			if (distance < bestDistance) {
				bestDistance = distance;
				best = name;
			}
		}
	}
	return $multi(best, bestDistance);
}

// keysite.c:507-568 initialise_keysite_farp_enable: FARPs start out of use and activate only when
// their sector side matches their force side. Bases are the port's sector proxy; activation latches.
function sectorSideFriendly(farpName: string): boolean {
	const farpPos = S.base_pos[farpName];
	const farpSide = S.base_owner[farpName];
	if (farpPos === undefined || farpSide === undefined) return false;
	let bestOwner: Side | undefined;
	let bestDistance = math.huge;
	for (const [name, owner] of pairs(S.base_owner)) {
		const basePos = S.base_pos[name];
		if (
			name !== farpName &&
			S.base_kind[name] !== "farp" &&
			basePos !== undefined
		) {
			const distance = cs.dist2d(farpPos.x, farpPos.z, basePos.x, basePos.z);
			if (distance < bestDistance) {
				bestDistance = distance;
				bestOwner = owner;
			}
		}
	}
	return bestOwner === farpSide;
}

export function seed_activation(logFn: LogFunction = () => undefined): void {
	S.farp_active ??= {};
	const gate = config.C.theatre.farp_activation;
	let activeCount = 0;
	let dormantCount = 0;
	for (const [name, kind] of pairs(S.base_kind)) {
		if (kind === "farp") {
			const active = !gate || sectorSideFriendly(name);
			if (active) {
				S.farp_active[name] = true;
				activeCount++;
			} else {
				delete S.farp_active[name];
				dormantCount++;
			}
		}
	}
	logFn(
		string.format(
			"FARP activation (gate=%s): %d active, %d dormant (dormant activate as the front nears)",
			tostring(gate),
			activeCount,
			dormantCount,
		),
	);
	cs.dbg(
		"farps",
		"seed_activation gate=%s: %d active, %d dormant",
		tostring(gate),
		activeCount,
		dormantCount,
	);
}

export function update(logFn: LogFunction = () => undefined): void {
	S.farp_active ??= {};
	if (!config.C.theatre.farp_activation) return;
	for (const [name, kind] of pairs(S.base_kind)) {
		if (kind === "farp" && !S.farp_active[name] && sectorSideFriendly(name)) {
			S.farp_active[name] = true;
			logFn(
				string.format(
					"FARP %s ACTIVATED — sector now friendly (front reached)",
					name,
				),
			);
			cs.dbg(
				"farps",
				"FARP %s ACTIVATED (sector friendly, keysite.c:541 proxy)",
				name,
			);
		}
	}
}

export function schedule(logFn: LogFunction = () => undefined): void {
	const generation = _DMT_GEN;
	const period = ACTIVATION_POLL_SECONDS;
	cs.dbg("farps", "activation scheduler REGISTERED period=%ds", period);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			pcall(() => update(logFn));
			return time + period;
		},
		undefined,
		timer.getTime() + period,
	);
}

export function init(logFn: LogFunction = () => undefined): void {
	pcall(() =>
		math.randomseed(
			math.floor(timer.getTime() * MILLISECONDS_PER_SECOND) +
				cs.GENERATION * GENERATION_SEED_PRIME,
		),
	);

	// Authored theatre: generated missions carry FARP trigger zones, not Mission Editor heliport
	// objects. Materialise one physical DCS FARP at each logical base so it is visible and usable.
	if (zones.has_keysite_zones()) {
		let farpCount = 0;
		let spawnedCount = 0;
		for (const [name, kind] of pairs(S.base_kind)) {
			if (kind !== "farp") continue;
			farpCount++;
			const owner = S.base_owner[name];
			const position = S.base_pos[name];
			if (
				(owner === BLUE || owner === RED) &&
				position !== undefined &&
				ensurePhysicalFarp(name, owner, position)
			)
				spawnedCount++;
		}
		logFn(
			string.format(
				"base roles from zones: %d farp bases confirmed, %d physical FARP statics queued — airbase/farp roles set by keysite zones",
				farpCount,
				spawnedCount,
			),
		);
		cs.dbg(
			"farps",
			"init (zone-authored): %d farp bases confirmed, %d physical statics queued",
			farpCount,
			spawnedCount,
		);
		seed_activation(logFn);
		return;
	}

	let fixedWingCountTotal = 0;
	let fobCount = 0;
	for (const side of SIDES) {
		const fields: RatedField[] = [];
		for (const [name, owner] of pairs(S.base_owner)) {
			if (owner === side) {
				const [, distance] = nearestEnemy(name, side);
				fields.push({ name, distance });
			}
		}
		fields.sort((a, b) => b.distance - a.distance);
		const fixedWingForSide = fixedWingCount(fields.length);
		for (let index = 0; index < fields.length; index++) {
			if (index < fixedWingForSide) {
				S.base_kind[fields[index].name] = "airbase";
				fixedWingCountTotal++;
			} else {
				S.base_kind[fields[index].name] = "fob";
				fobCount++;
			}
		}
	}

	const airfields: FieldOwner[] = [];
	for (const [name, owner] of pairs(S.base_owner)) {
		if (S.base_kind[name] === "airbase" || S.base_kind[name] === "fob") {
			airfields.push({ name, owner });
		}
	}
	let farpCount = 0;
	for (const airfield of airfields) {
		const [enemyBase, distance] = nearestEnemy(airfield.name, airfield.owner);
		if (
			enemyBase !== undefined &&
			distance < FRONT_DIST &&
			math.random(RANDOM_PERCENT_MAX) <= FARP_PLACEMENT_CHANCE_PERCENT
		) {
			const basePos = S.base_pos[airfield.name];
			const enemyPos = S.base_pos[enemyBase];
			const dx = enemyPos.x - basePos.x;
			const dz = enemyPos.z - basePos.z;
			const length = math.max(math.sqrt(dx * dx + dz * dz), 1);
			const unitX = dx / length;
			const unitZ = dz / length;
			const perpendicularX = -unitZ;
			const perpendicularZ = unitX;
			const forward =
				FARP_FORWARD_MIN_METRES +
				math.random() * (FARP_FORWARD_MAX_METRES - FARP_FORWARD_MIN_METRES);
			const lateral = (math.random() * 2 - 1) * FARP_LATERAL_JITTER_METRES;
			const farpPos = cs.snap_land(
				basePos.x + unitX * forward + perpendicularX * lateral,
				basePos.z + unitZ * forward + perpendicularZ * lateral,
				basePos.x,
				basePos.z,
			);
			const farpName = `FARP-${string.sub(airfield.name, 1, 12)}`;
			S.base_owner[farpName] = airfield.owner;
			S.base_pos[farpName] = { x: farpPos.x, z: farpPos.z };
			S.base_health[farpName] = 1;
			S.base_kind[farpName] = "farp";

			ensurePhysicalFarp(farpName, airfield.owner, farpPos);
			farpCount++;
		}
	}

	logFn(
		string.format(
			"base roles: %d fixed-wing AIRBASEs (rear) + %d heli-only FOBs + %d forward FARPs — fixed-wing flies only from airbases; the rotary front war flies from FOBs + FARPs",
			fixedWingCountTotal,
			fobCount,
			farpCount,
		),
	);
	cs.dbg(
		"farps",
		"init (auto): %d airbases, %d heli-only FOBs, %d forward FARPs placed",
		fixedWingCountTotal,
		fobCount,
		farpCount,
	);
	seed_activation(logFn);
}
