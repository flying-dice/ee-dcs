/** @noSelfInFile */
/*
-- transfer.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--
-- create_fixed_wing_transfer_tasks()  line 2132
--   Period:  15.0*ONE_MINUTE (skirmish line 232 / campaign line 262)
--   Offsets: 34.0 s (skirmish) / 2.5*ONE_MINUTE=150 s (campaign)
--   Score: base_dist*4 + (1 - min(idle_count,4)*0.25)*4;  max=8.0
--   Commented-out terms (importance, airdef, surfdef) are NOT included.
--   Pairing: sort descending; top CREATE_TRANSFER_TASK_COUNT=3 receive from bottom donors.
--     keysite_count = min(count/2, CREATE_TRANSFER_TASK_COUNT)  (line 2294)
--     donar = target_list[loop2]  (highest index = lowest rating = most idle aircraft)
--     target = target_list[loop]  (lowest index = highest rating = most needed reinforcement)
--     Condition: donor != target; target has landing sites available.
--
-- create_helicopter_transfer_tasks() line 2352
--   Period:  10.0*ONE_MINUTE (skirmish line 238) / 7.5*ONE_MINUTE (campaign line 260)
--   Offsets: 3.0*ONE_MINUTE=180 s (skirmish) / 2.0*ONE_MINUTE=120 s (campaign)
--   Score: IDENTICAL formula and max to fixed-wing (same source block, same coefficients).
--
-- EECH constants:
--   CREATE_TRANSFER_TASK_COUNT = 3 (line 102)
--   MAX_HIGHLEVEL_TARGET_CHECKS = 160 (line 84)
--
-- DCS proxy notes:
--   EECH transfers fly real aircraft from donor keysite to target keysite via task.
--   DCS proxy: immediately adjust supply.available() counts — consume from donor,
--   produce at target.  No flight is spawned; the aircraft materialises at the new base.
--   idle_group_count proxy: supply.available(base, type) — more reserve = more idle.
--   Clamped to [0, 4] then ×0.25, matching EECH: min(idle, 4.0f) × 0.25.
*/

import * as mode from "./campaign_mode";
import * as cs from "./campaign_state";
import type { Side } from "./campaign_types";
import * as imap from "./imap";
import type { Role } from "./supply";
import * as supply from "./supply";

type LogFunction = (this: void, message: string) => void;

interface Rating {
	name: string;
	rating: number;
}

const CREATE_TRANSFER_TASK_COUNT = 3; // highlevl.c line 102
const _MAX_HIGHLEVEL_TARGET_CHECKS = 160; // highlevl.c line 84
const _TRANSFER_MAX_RATING = 8.0; // highlevl.c lines 2264, 2474

const PERIOD_FW = mode.SCHED.fw_transfer.period;
const OFFSET_FW = mode.SCHED.fw_transfer.blue;
const PERIOD_HC = mode.SCHED.hc_transfer.period;
const OFFSET_HC = mode.SCHED.hc_transfer.blue;
// DCS adapter proxy radius in metres for associating fielded groups with a base.
const IDLE_RADIUS_METRES = 5000;
// Verified in highlevl.c:2258-2263 and :2478-2483.
const TRANSFER_BASE_DISTANCE_WEIGHT = 4.0;
const TRANSFER_IDLE_WEIGHT = 4.0;
const IDLE_GROUP_COUNT_CAP = 4.0;
const IDLE_GROUP_FRACTION_PER_GROUP = 0.25;

const S = cs.S;

function updateIdleGroups(side: number): void {
	S.base_idle_groups ??= {};
	const radiusSquared = IDLE_RADIUS_METRES * IDLE_RADIUS_METRES;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side) S.base_idle_groups[name] = 0;
	}
	const groups = coalition.getGroups(side);
	if (groups === undefined) return;
	for (const group of groups) {
		if (group !== undefined && group.isExist()) {
			const unit = group.getUnit(1);
			if (unit !== undefined && unit.isExist()) {
				const groupPos = unit.getPosition().p;
				for (const [name, owner] of pairs(S.base_owner)) {
					if (owner === side) {
						const basePos = S.base_pos[name];
						if (basePos !== undefined) {
							const dx = groupPos.x - basePos.x;
							const dz = groupPos.z - basePos.z;
							if (dx * dx + dz * dz <= radiusSquared) {
								S.base_idle_groups[name] = (S.base_idle_groups[name] ?? 0) + 1;
							}
						}
					}
				}
			}
		}
	}
}

function idleFraction(baseName: string): number {
	const count = S.base_idle_groups?.[baseName] ?? 0;
	return math.min(count, IDLE_GROUP_COUNT_CAP) * IDLE_GROUP_FRACTION_PER_GROUP;
}

// rating = base_dist*4 + (1-idle_fraction)*4. Commented-out EECH importance/defence terms remain
// excluded. IMAP_BASE_DISTANCE is queried for the enemy side.
function scoreBase(baseName: string, enemySide: Side): number {
	const basePos = S.base_pos[baseName];
	if (basePos === undefined) return 0;
	const health = S.base_health[baseName] ?? 0;
	if (health < cs.HEALTH_NEUTRALISED) return 0;
	const baseDistance = imap.get(enemySide, imap.BASE_DISTANCE, basePos);
	return (
		baseDistance * TRANSFER_BASE_DISTANCE_WEIGHT +
		(1.0 - idleFraction(baseName)) * TRANSFER_IDLE_WEIGHT
	);
}

function doTransfer(
	aircraftType: Role,
	donorName: string,
	targetName: string,
	side: number,
	logFn: LogFunction,
): boolean {
	if (!supply.consume(donorName, aircraftType, 1)) {
		logFn(
			string.format("transfer: no %s at donor %s", aircraftType, donorName),
		);
		cs.dbg(
			"transfer",
			"%s transfer ABORT: no %s at donor %s",
			cs.SIDE_NAME[side],
			aircraftType,
			donorName,
		);
		return false;
	}
	supply.produce(targetName, aircraftType, 1);
	logFn(
		string.format(
			"%s transfer (%s): %s → %s",
			cs.SIDE_NAME[side],
			aircraftType,
			donorName,
			targetName,
		),
	);
	cs.dbg(
		"transfer",
		"%s transfer: 1x %s %s -> %s",
		cs.SIDE_NAME[side],
		aircraftType,
		donorName,
		targetName,
	);
	return true;
}

function runTransfer(
	side: number,
	aircraftType: Role,
	logFn: LogFunction,
): void {
	const enemy = cs.ENEMY[side];
	updateIdleGroups(side);
	const ratings: Rating[] = [];
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side) {
			const rating = scoreBase(name, enemy);
			if (rating > 0) ratings.push({ name, rating });
		}
	}
	if (ratings.length < 2) {
		cs.dbg(
			"transfer",
			"%s %s: only %d usable base(s) rated, skipping (need >=2)",
			cs.SIDE_NAME[side],
			aircraftType,
			ratings.length,
		);
		return;
	}

	ratings.sort((a, b) => b.rating - a.rating);
	const keysiteCount = math.min(
		math.floor(ratings.length / 2),
		CREATE_TRANSFER_TASK_COUNT,
	);
	let donorIndex = ratings.length - 1;
	let completed = 0;
	for (let targetIndex = 0; targetIndex < keysiteCount; targetIndex++) {
		const target = ratings[targetIndex];
		const donor = ratings[donorIndex];
		if (
			target.name !== donor.name &&
			supply.available(donor.name, aircraftType) > 0 &&
			doTransfer(aircraftType, donor.name, target.name, side, logFn)
		) {
			completed++;
		}
		donorIndex--;
	}
	cs.dbg(
		"transfer",
		"%s %s: %d bases rated -> %d pairing slots -> %d transfers executed",
		cs.SIDE_NAME[side],
		aircraftType,
		ratings.length,
		keysiteCount,
		completed,
	);
}

export function schedule_fw_transfer(
	side: number,
	initialOffset?: number,
	logFn: LogFunction = () => undefined,
): void {
	const generation = _DMT_GEN;
	const offset = initialOffset ?? OFFSET_FW;
	cs.dbg(
		"transfer",
		"%s FW transfer scheduler REGISTERED offset=%.0fs period=%.0fs",
		cs.SIDE_NAME[side],
		offset,
		PERIOD_FW,
	);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			cs.dbg("transfer", "%s FW transfer FIRE", cs.SIDE_NAME[side]);
			const [ok, error] = pcall(() => {
				runTransfer(side, "striker", logFn);
				runTransfer(side, "escort", logFn);
			});
			if (!ok) logFn(`FW transfer error: ${tostring(error)}`);
			return time + PERIOD_FW;
		},
		undefined,
		timer.getTime() + offset,
	);
}

export function schedule_hc_transfer(
	side: number,
	initialOffset?: number,
	logFn: LogFunction = () => undefined,
): void {
	const generation = _DMT_GEN;
	const offset = initialOffset ?? OFFSET_HC;
	cs.dbg(
		"transfer",
		"%s HC transfer scheduler REGISTERED offset=%.0fs period=%.0fs",
		cs.SIDE_NAME[side],
		offset,
		PERIOD_HC,
	);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			cs.dbg("transfer", "%s HC transfer FIRE", cs.SIDE_NAME[side]);
			const [ok, error] = pcall(() => runTransfer(side, "heli", logFn));
			if (!ok) logFn(`HC transfer error: ${tostring(error)}`);
			return time + PERIOD_HC;
		},
		undefined,
		timer.getTime() + offset,
	);
}
