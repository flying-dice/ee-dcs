/** @noSelfInFile */
/*
-- troop.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--
-- create_troop_insertion_tasks() line 1660
--   Period: 2.0*ONE_MINUTE (skirmish line 234) / 2.0*ONE_MINUTE (campaign line 256) → SAME both modes
--   Offset: 60 s (skirmish) / 1.0*ONE_MINUTE=60 s (campaign)
--   Targets: enemy keysites where keysite_database[type].troop_insertion_target==true
--            AND efficiency < minimum_efficiency
--   Score: (1-airdef)*1 + base_dist*3 + (1-efficiency)*3 + sector_ratio*2; max=9.0
--   Limits: CREATE_TROOP_INSERTION_TASK_COUNT=2 (line 97), MIN_TASK_CREATION_RATIO=0.75
--   FOW: fow >= 0.20 * maximum (line 1819: if fow < 0.20 → create recon instead)
--   NOTE: commented-out "low enemy importance" term not included (line source: // rating += ...)
--
-- create_troop_patrol_tasks() line 2735
--   Period: 10.0*ONE_MINUTE (skirmish line 230) / 5.0*ONE_MINUTE (campaign line 248)
--   Offset: 5 s (both modes)
--   Targets: own FARP, military base, airbase keysites
--   Limit: 1 patrol group per keysite (groups_limit=1 line 2775)
--   Group: 4 infantry units (FORMATION_COMPONENT_INFANTRY, count=4, line 2812)
--   Spawn radius: 300 + frand1()*50 metres from keysite (line 2805-2808)
--   Capture mechanic: patrol task → guard area; if enemy keysite switches → reaction chain
--
-- Capture-on-ARRIVAL (eech mb_msgs.c:2260-2325, response_to_waypoint_troop_capture_reached):
--   EECH fires the capture roll when the insertion group physically REACHES the TROOP_CAPTURE
--   waypoint at the destination keysite — NOT at dispatch, and with NO offload delay. The port
--   mirrors this 1:1: check_landing_helis detects the "Insert-*" heli arriving within
--   CAPTURE_RADIUS_METRES of ITS OWN registered target_base (never any other base the flight line passes)
--   and rolls IMMEDIATELY — members = surviving units, losses = units lost en route (eech reads the
--   GROUP's INT_TYPE_MEMBER_COUNT / INT_TYPE_LOSSES at 2293-2295), against the keysite's CURRENT
--   efficiency (FLOAT_TYPE_EFFICIENCY read at the event, 2283) — a base repaired above minimum
--   REPELS. A transport shot down en route never reaches the waypoint → no roll (eech: task
--   terminates on group death), and the DEAD handler clears the task + slot. On a won roll
--   keysite.do_capture applies side flip + instant repair + regen reseed + win re-check
--   (eech capture_keysite, keysite.c:1289-1518).
--
-- EECH constants referenced:
--   CREATE_TROOP_INSERTION_TASK_COUNT = 2 (highlevl.c line 97)
--   MIN_TASK_CREATION_RATIO           = 0.75 (highlevl.c line 90)
--   MAX_HIGHLEVEL_TARGET_CHECKS       = 160 (highlevl.c line 84)
*/

import * as mode from "./campaign_mode";
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as croute from "./croute";
import * as farpParking from "./farp_parking";
import * as fow from "./fog_of_war";
import * as imap from "./imap";
import * as keysite from "./keysite";
import * as board from "./task_board";

const S = cs.S;
type LogFn = (message: string) => void;
const CREATE_COUNT = 2,
	MIN_RATIO = 0.75,
	MAX_CHECKS = 160,
	FOW_THRESHOLD = 0.2;
// Verified score coefficients from highlevl.c:1723-1764.
const INSERT_AIR_DEFENCE_WEIGHT = 1;
const INSERT_BASE_DISTANCE_WEIGHT = 3;
const INSERT_EFFICIENCY_WEIGHT = 3;
const INSERT_SECTOR_RATIO_WEIGHT = 2;
const PERIOD_TI = mode.SCHED.troop_insertion.period,
	OFFSET_TI = mode.SCHED.troop_insertion.blue;
const PERIOD_PATROL = mode.SCHED.patrol.period,
	OFFSET_PATROL = mode.SCHED.patrol.blue;
// DCS adapter values in metres/seconds; EECH capture fires on waypoint arrival, but DCS has no
// equivalent callback for dynamically spawned routes, so proximity and a stale-task TTL are used.
const CAPTURE_RADIUS_METRES = 8000,
	INSERT_TTL_SECONDS = 45 * 60,
	SECTOR_RADIUS_METRES = 200000;
// Verified against highlevl.c:2800-2812 and FORMATION_COMPONENT_INFANTRY.
const PATROL_COUNT = 4,
	PATROL_RADIUS_METRES = 300,
	PATROL_JITTER_METRES = 50,
	PATROL_GUARD_RADIUS_METRES = 500;
const TROOP_MEMBER_FALLBACK = 4;
// DCS adapter flight and formation values (metres, metres/second, and countermeasure quantities).
const INSERT_ALTITUDE_METRES = 150;
const INSERT_SPEED_METRES_PER_SECOND = 100;
const INSERT_UNIT_SPACING_METRES = 30;
const TRANSPORT_FUEL_KILOGRAMS = 2200;
const TRANSPORT_FLARE_COUNT = 60;
const TRANSPORT_CHAFF_COUNT = 60;
const PAYLOAD_GUN_PERCENT = 100;
const AIRBASE_INSERT_TRANSPORT_COUNT = 2;
const STANDARD_INSERT_TRANSPORT_COUNT = 1;
const PATROL_UNIT_SPACING_METRES = 5;
const PATROL_WALK_SPEED_METRES_PER_SECOND = 1.4;
const TRANSPORT: Record<number, { country: number; type: string }> = {};
const INFANTRY: Record<number, { country: number; type: string }> = {};
for (const side of [coalition.side.BLUE, coalition.side.RED]) {
	TRANSPORT[side] = {
		country: config.C.countries[side],
		type: config.C.types.aircraft[side].transport_heli,
	};
	INFANTRY[side] = {
		country: config.C.countries[side],
		type: config.C.types.ground.infantry[side],
	};
}
function ratio(pos: WorldPoint, side: Side): number {
	let friendly = 0,
		total = 0;
	for (const [name, owner] of Object.entries(S.base_owner)) {
		const base = S.base_pos[name];
		if (base === undefined) continue;
		const dx = pos.x - base.x,
			dz = pos.z - base.z;
		if (dx * dx + dz * dz <= SECTOR_RADIUS_METRES ** 2) {
			total += 1;
			if (owner === side) friendly += 1;
		}
	}
	return total === 0 ? 0 : friendly / total;
}
// TSTL/Lua-interop correctness helper — NOT a campaign constant, so there is deliberately no
// EECH citation for it. `string.match()` is typed as a LuaMultiReturn; used directly inside an
// expression, typescript-to-lua wraps it in a table constructor — `({string.match(n, p)})` —
// which is never nil. That made every `string.match(n, p) !== undefined` test ALWAYS TRUE (and
// every `=== undefined` test always false). Destructuring forces the single-value form
// (`local found = string.match(n, p)`), matching the Lua baseline's `n:match(...)` tests.
function matches(text: string, pattern: string): boolean {
	const [found] = string.match(text, pattern);
	return found !== undefined;
}
function checkArrivals(side: Side, logFn: LogFn): void {
	for (const group of coalition.getGroups(side) ?? []) {
		if (!group.isExist()) continue;
		const name = group.getName(),
			task = cs.get_task(name);
		const insertion =
			matches(name, "^Insert") ||
			(task?.player === true && task.task_type === "troop_insertion");
		const baseName = task?.target_base;
		if (
			!insertion ||
			S.pending_captures[name] ||
			baseName === undefined ||
			S.base_owner[baseName] === side
		)
			continue;
		const unit = group.getUnit(1),
			base = S.base_pos[baseName];
		if (unit === undefined || !unit.isExist() || base === undefined) continue;
		const pos = unit.getPosition().p,
			dx = pos.x - base.x,
			dz = pos.z - base.z;
		if (dx * dx + dz * dz > CAPTURE_RADIUS_METRES ** 2) continue;
		let members = TROOP_MEMBER_FALLBACK;
		let losses = 0;
		const [sizeOk, size] = pcall(() => group.getSize());
		if (sizeOk && size !== undefined) {
			members = Math.max(1, size);
			const [initialOk, initialSize] = pcall(() => group.getInitialSize?.());
			if (initialOk && initialSize !== undefined)
				losses = Math.max(0, initialSize - members);
		}
		S.pending_captures[name] = true;
		if (keysite.capture_roll(baseName, members, losses)) {
			keysite.do_capture(baseName, side, logFn);
			cs.stat_task_result(side, "success");
		} else cs.stat_task_result(side, "failure");
		cs.clear_task(name);
		keysite.release_slot(name);
	}
}
function buildInsert(
	side: Side,
	baseName: string,
	targetName: string,
	target: WorldPoint,
	logFn: LogFn,
	members: number,
): Group | undefined {
	const airbase = Airbase.getByName(baseName),
		logical = S.base_pos[baseName];
	if (airbase === undefined && logical === undefined) return undefined;
	let p: Vec3;
	if (airbase !== undefined) p = airbase.getPosition().p;
	else if (logical !== undefined)
		p = {
			x: logical.x,
			y: land.getHeight({ x: logical.x, y: logical.z }),
			z: logical.z,
		};
	else return undefined;
	const id = airbase?.getID(),
		cfg = TRANSPORT[side],
		sid = cs.next_id(),
		name = string.format(
			"Insert-%s-%d-%d",
			string.sub(targetName, 1, 8),
			side,
			sid,
		);
	const units: UnitData[] = [];
	for (let i = 0; i < members; i += 1)
		units.push({
			name: `${name}-${i + 1}`,
			type: cfg.type,
			skill: "Good",
			x: p.x + i * INSERT_UNIT_SPACING_METRES,
			y: p.z,
			alt: p.y,
			alt_type: "BARO",
			speed: 0,
			heading: 0,
			payload: {
				fuel: TRANSPORT_FUEL_KILOGRAMS,
				flare: TRANSPORT_FLARE_COUNT,
				chaff: TRANSPORT_CHAFF_COUNT,
				gun: PAYLOAD_GUN_PERCENT,
			},
		});
	const depart: WaypointData =
		id !== undefined
			? {
					type: "TakeOffParkingHot",
					action: "From Parking Area Hot",
					airdromeId: id,
					alt: p.y,
					alt_type: "BARO",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: p.x,
					y: p.z,
					name: "Depart",
					formation_template: "",
				}
			: {
					type: "TakeOffGroundHot",
					action: "From Ground Area Hot",
					alt: p.y,
					alt_type: "BARO",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: p.x,
					y: p.z,
					name: "Depart",
					formation_template: "",
				};
	const spec: GroupData = {
		name,
		task: "Transport",
		hidden: false,
		units,
		route: {
			points: croute.expand(
				[
					depart,
					{
						type: "Turning Point",
						action: "Turning Point",
						alt: INSERT_ALTITUDE_METRES,
						alt_type: "BARO",
						speed: INSERT_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						x: target.x,
						y: target.z,
						name: "Insert",
						formation_template: "",
					},
				],
				side,
				{
					alt: INSERT_ALTITUDE_METRES,
					alt_type: "BARO",
					speed: INSERT_SPEED_METRES_PER_SECOND,
					name: "Nav",
				},
			),
		},
	};
	if (airbase !== undefined)
		farpParking.configureDeparture(baseName, airbase, spec, depart);
	const group = coalition.addGroup(
		cfg.country,
		Group.Category.HELICOPTER,
		spec,
	);
	if (group === undefined) return undefined;
	cs.register_task(name, {
		task_type: "troop_insertion",
		side,
		target_base: targetName,
		target_pos: target,
		objective: { kind: "keysite", base: targetName },
		born_time: timer.getTime(),
	});
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		() => {
			if (_DMT_GEN === generation && cs.get_task(name) !== undefined) {
				cs.clear_task(name);
				keysite.release_slot(name);
			}
			return undefined;
		},
		undefined,
		timer.getTime() + INSERT_TTL_SECONDS,
	);
	if (cs.escort_count("troop_insertion", side, p, target, logFn) > 0) {
		const heli = require<typeof import("./heli_war")>("heli_war");
		pcall(() => heli.spawn_escort(side, target, logFn));
	}
	return group;
}
function createInsert(
	side: Side,
	name: string,
	pos: WorldPoint,
	logFn: LogFn,
	immediate: boolean,
): boolean {
	const members =
		S.base_kind[name] === "airbase" && S.base_owner[name] !== side
			? AIRBASE_INSERT_TRANSPORT_COUNT
			: STANDARD_INSERT_TRANSPORT_COUNT;
	board.create_task({
		type: "troop_insertion",
		side,
		count: members,
		log_fn: logFn,
		immediate,
		target: { base: name, pos, objective: { kind: "keysite", base: name } },
		builder: (base) => buildInsert(side, base, name, pos, logFn, members),
	});
	return true;
}
function runInsertion(side: Side, logFn: LogFn, directed?: string): void {
	if (directed !== undefined) {
		const pos = S.base_pos[directed];
		if (
			pos !== undefined &&
			!cs.has_task_against("troop_insertion", directed, side)
		)
			createInsert(side, directed, pos, logFn, true);
		return;
	}
	const rated: Array<{ name: string; pos: WorldPoint; rating: number }> = [];
	for (const [name, owner] of Object.entries(S.base_owner))
		if (rated.length < MAX_CHECKS && owner === cs.ENEMY[side]) {
			const pos = S.base_pos[name],
				efficiency = S.base_efficiency[name] ?? S.base_health[name] ?? 1;
			if (pos === undefined || efficiency >= cs.MINIMUM_EFFICIENCY) continue;
			if ((fow.get(name, side) ?? 0) < FOW_THRESHOLD) {
				if (!cs.has_task_against("recon", name, side))
					require<typeof import("./recon")>("recon").spawn_recon(
						side,
						{ x: pos.x, y: pos.y ?? 0, z: pos.z },
						`TIscout-${string.sub(name, 1, 8)}`,
						logFn,
						{ kind: "keysite", base: name },
					);
				continue;
			}
			const rating =
				(1 - imap.get(side, imap.AIR_DEFENCE, pos)) *
					INSERT_AIR_DEFENCE_WEIGHT +
				imap.get(side, imap.BASE_DISTANCE, pos) * INSERT_BASE_DISTANCE_WEIGHT +
				(1 - efficiency) * INSERT_EFFICIENCY_WEIGHT +
				ratio(pos, side) * INSERT_SECTOR_RATIO_WEIGHT;
			if (rating > 0) rated.push({ name, pos, rating });
		}
	rated.sort((a, b) => b.rating - a.rating);
	if (rated.length === 0) return;
	for (let i = 0; i < Math.min(rated.length, CREATE_COUNT); i += 1) {
		const entry = rated[i];
		if (
			entry.rating / rated[0].rating >= MIN_RATIO &&
			!cs.has_task_against("troop_insertion", entry.name, side)
		) {
			createInsert(side, entry.name, entry.pos, logFn, true);
			const defender = S.base_owner[entry.name];
			if (
				defender !== side &&
				!cs.has_task_against("troop_insertion", entry.name, defender)
			)
				createInsert(defender, entry.name, entry.pos, logFn, true);
		}
	}
}

function hasPatrol(base: string): boolean {
	const name = S.patrol_groups[base];
	return name !== undefined && Group.getByName(name)?.isExist() === true;
}
function spawnPatrol(baseName: string, side: Side, logFn: LogFn): void {
	if (hasPatrol(baseName)) return;
	const base = S.base_pos[baseName];
	if (base === undefined) return;
	const angle = math.random() * Math.PI * 2,
		radius = PATROL_RADIUS_METRES + math.random() * PATROL_JITTER_METRES;
	const start = cs.snap_land(
		base.x + Math.cos(angle) * radius,
		base.z + Math.sin(angle) * radius,
		base.x,
		base.z,
	);
	const cfg = INFANTRY[side],
		id = cs.next_id(),
		name = string.format("Patrol-%s-%d", string.sub(baseName, 1, 10), id);
	const units: UnitData[] = [];
	for (let i = 0; i < PATROL_COUNT; i += 1)
		units.push({
			name: `${name}-${i + 1}`,
			type: cfg.type,
			skill: "Good",
			x: start.x + i * PATROL_UNIT_SPACING_METRES,
			y: start.z,
			alt: land.getHeight({ x: start.x, y: start.z }),
			alt_type: "BARO",
			speed: 0,
			heading: 0,
			playerCanDrive: false,
		});
	const group = coalition.addGroup(cfg.country, Group.Category.GROUND, {
		name,
		task: "Ground Nothing",
		hidden: false,
		units,
		route: {
			points: [
				{
					type: "Turning Point",
					action: "Turning Point",
					x: start.x,
					y: start.z,
					speed: PATROL_WALK_SPEED_METRES_PER_SECOND,
					ETA: 0,
					ETA_locked: false,
					formation_template: "",
					task: {
						id: "ComboTask",
						params: {
							tasks: [
								{
									number: 1,
									auto: true,
									id: "Guard",
									enabled: true,
									params: {
										zone: { x: start.x, y: start.z },
										radius: PATROL_GUARD_RADIUS_METRES,
									},
								},
							],
						},
					},
				},
			],
		},
	});
	if (group !== undefined) {
		S.patrol_groups[baseName] = name;
		logFn(
			string.format(
				"%s patrol spawned at %s (#%d, %d units)",
				cs.SIDE_NAME[side],
				baseName,
				id,
				PATROL_COUNT,
			),
		);
	}
}
function runPatrol(side: Side, logFn: LogFn): void {
	for (const [name, owner] of Object.entries(S.base_owner))
		if (owner === side && (S.base_health[name] ?? 1) >= cs.HEALTH_NEUTRALISED)
			spawnPatrol(name, side, logFn);
}
export function run_troop_insertion(
	side: Side,
	logFn: LogFn = () => undefined,
	targetName?: string,
): void {
	const [ok, error] = pcall(() => runInsertion(side, logFn, targetName));
	if (!ok) logFn(`run_troop_insertion error: ${tostring(error)}`);
}
export function schedule_troop_insertion(
	side: Side,
	initialOffset = OFFSET_TI,
	logFn: LogFn = () => undefined,
): void {
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => {
				checkArrivals(side, logFn);
				runInsertion(side, logFn);
			});
			if (!ok) logFn(`T.I. error: ${tostring(error)}`);
			return time + PERIOD_TI;
		},
		undefined,
		timer.getTime() + initialOffset,
	);
}
export function schedule_patrol(
	side: Side,
	initialOffset = OFFSET_PATROL,
	logFn: LogFn = () => undefined,
): void {
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => runPatrol(side, logFn));
			if (!ok) logFn(`patrol error: ${tostring(error)}`);
			return time + PERIOD_PATROL;
		},
		undefined,
		timer.getTime() + initialOffset,
	);
}
