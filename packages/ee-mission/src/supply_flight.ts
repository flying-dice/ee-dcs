/** @noSelfInFile */
/*
-- supply_flight.lua
-- PHYSICAL supply flights — the transport that actually flies a resupply crate from a producer
-- keysite to a low consumer keysite, replacing the old instant-crate teleport in keysite_repair.
--
-- EECH source:
--   aphavoc/source/entity/special/force/fc_msgs.c:672-870  response_to_force_low_on_supplies:
--     a keysite whose ammo/fuel supply level fell to KEYSITE_SUPPLY_REQUEST_THRESHOLD (75.0,
--     en_suply.h:87) raises ENTITY_MESSAGE_FORCE_LOW_ON_SUPPLIES (keysite.c:469-494). The FORCE
--     picks the CLOSEST supplier — AMMO: nearest FACTORY (fall back OIL_REFINERY), FUEL: nearest
--     OIL_REFINERY (fall back FACTORY); an AIRBASE within range may substitute if closer
--     (fc_msgs.c:759-800) — then finds the matching cargo crate and calls create_supply_task with
--     movement_type = MOVEMENT_TYPE_AIR (fc_msgs.c:846 — the land-convoy branch is commented out in
--     the shipped source, fc_msgs.c:834-845). Dedup: one supply task per keysite PER CARGO SUB_TYPE
--     (entity_is_object_of_task + FLOAT_TYPE_TASK_USER_DATA==sub_type, fc_msgs.c:721-742).
--   aphavoc/source/ai/taskgen/taskgen.c:1638-1727  create_supply_task: TASK_SUPPLY with waypoints
--     PICK_UP (at the cargo/producer, :1707), PREPARE_FOR_DROP_OFF (stop - dir*4km, :1688-1690),
--     DROP_OFF (requester supply position, :1709), FINISH_DROP_OFF (stop + dir*2km, :1692-1694);
--     expire_time = 20*ONE_MINUTE (:1696). Start keysite = get_task_start_keysite (a friendly
--     keysite with idle transports) — the task board's launch-base selection is the port analog.
--   aphavoc/source/entity/special/task/ts_dbase.c:1386-1440  TASK_SUPPLY row: task_priority 4,
--     Escort Required Threshold 6, Movement Type MOVEMENT_TYPE_AIR, landing types
--     LANDING_FIXED_WING_TRANSPORT + LANDING_HELICOPTER, Cargo Space 5, Engage Enemy FALSE.
--   aphavoc/source/entity/special/keysite/keysite.c:337-467  update_keysite_cargo / ks_msgs.c:230,238
--     one crate delivery restocks the consumer keysite to 100.
--
-- PORT MODEL (documented divergences from the C):
--   * MOVEMENT_TYPE_AIR only. EECH's create_supply_task also serves land convoys when the caller
--     picks MOVEMENT_TYPE_LAND, but fc_msgs.c:846 hardcodes AIR for keysite resupply (the land branch
--     is commented out), and DCS exposes no road-node adjacency graph for a node-by-node convoy (the
--     documented structural road-graph limit shared with ground movement) — so AIR is both faithful to
--     the live caller and the only reproducible option.
--   * The "cargo crate" is the side-level production accumulator (supply.lua S.production), not a
--     per-factory cargo entity. The producer keysite (installations.nearest_producer) is used as the
--     PICK_UP position; the crate is debited from the accumulator at pick-up (flight spawn). A crate
--     requested but not yet picked up is EARMARKED (supply.earmark_crate) so convert_reserves cannot
--     turn it into a jet while the flight is queued — EECH's cargo, once claimed by a supply task, is
--     never repurposed.
--   * DROP_OFF is a fly-over of the consumer detected by proximity (check_arrivals); the transport
--     then RTBs and LANDS BACK AT ITS LAUNCH BASE (where the land handler recycles it to the transport
--     ledger). EECH lands at the requester; the port has no consumer-landing model, so restock is
--     triggered by the fly-over and the airframe returns home for recycle.
--   * Airframe: fixed-wing transport (config transport_fw: C-130 / An-26B) for airbase↔airbase legs;
--     transport heli (config transport_heli: UH-1H / Mi-8MT) whenever EITHER endpoint is a padless
--     FARP/FOB (no runway). Movement stays AIR either way (the ts_dbase landing types allow both).
--   * Shot down en route = crate LOST (debited at pick-up, never refunded) — the interceptable
--     economy this whole feature exists to create.
*/

import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as croute from "./croute";
import * as farpParking from "./farp_parking";
import * as installations from "./installations";
import * as keysite from "./keysite";
import type { Commodity } from "./supply";
import * as supply from "./supply";
import * as board from "./task_board";

type LogFunction = (this: void, message: string) => void;
interface Producer {
	name: string;
	pos: WorldPoint;
}
interface EscortModule {
	spawn_escort(
		side: Side,
		target: WorldPoint,
		logFn: LogFunction,
	): Group | undefined;
}

const S = cs.S;
const SUPPLY_SPEED = 100; // task_board transport cruise speed
const DELIVERY_RADIUS = 4000;
const ARRIVAL_SCAN_PERIOD = 20;
const FULL_SUPPLY_PERCENT = 100; // keysite.c:337-467; one delivered crate fully restocks a keysite.
// Fallback if DCS route state disappears: conservative cruise plus ten minutes
// for takeoff, approach and landing (preserved Lua adapter policy).
const BACKSTOP_MIN_SPEED_METRES_PER_SECOND = 40;
const BACKSTOP_MARGIN_SECONDS = 10 * 60;
const SUPPLY_PREFIX = "Supply";
const SIDES: Side[] = [coalition.side.BLUE, coalition.side.RED];

export function has_pending(
	side: Side,
	consumer: string,
	commodity: Commodity,
): boolean {
	for (const task of S.board_tasks) {
		if (
			task.state === "UNASSIGNED" &&
			task.type === "supply" &&
			task.side === side &&
			task.target.base === consumer &&
			task.target.commodity === commodity
		) {
			return true;
		}
	}
	for (const [, task] of pairs(S.active_tasks)) {
		if (
			task.task_type === "supply" &&
			task.side === side &&
			task.target_base === consumer &&
			task.commodity === commodity
		) {
			return true;
		}
	}
	return false;
}

export function count_queued(side: Side, commodity: Commodity): number {
	let count = 0;
	for (const task of S.board_tasks) {
		if (
			task.state === "UNASSIGNED" &&
			task.type === "supply" &&
			task.side === side &&
			task.target.commodity === commodity
		) {
			count++;
		}
	}
	return count;
}

function recycleSupplyOnce(
	groupName: string,
	launchBase: string,
	group: Group | undefined,
): void {
	if (S._recycled[groupName]) return;
	S._recycled[groupName] = true;
	let survivorCount = 0;
	if (group !== undefined && group.isExist()) {
		const [ok, units] = pcall(() => group.getUnits());
		if (ok && units !== undefined) {
			for (const unit of units) {
				if (unit !== undefined && unit.isExist()) survivorCount++;
			}
		}
	}
	if (survivorCount > 0)
		supply.recycle_base(launchBase, "transport", survivorCount);
}

function distance(left: WorldPoint, right: WorldPoint): number {
	const dx = left.x - right.x;
	const dz = left.z - right.z;
	return math.sqrt(dx * dx + dz * dz);
}

function scheduleBackstop(
	groupName: string,
	launchBase: string,
	group: Group,
	airbasePos: Vec3,
	producerPos: WorldPoint,
	consumerPos: WorldPoint,
): void {
	const routeDistance =
		distance(airbasePos, producerPos) +
		distance(producerPos, consumerPos) +
		distance(consumerPos, airbasePos);
	const timeToLive =
		routeDistance / BACKSTOP_MIN_SPEED_METRES_PER_SECOND +
		BACKSTOP_MARGIN_SECONDS;
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		(_argument: undefined, _time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			recycleSupplyOnce(groupName, launchBase, group);
			keysite.release_slot(groupName);
			if (group.isExist()) group.destroy();
			cs.clear_task(groupName);
			return undefined;
		},
		undefined,
		timer.getTime() + timeToLive,
	);
}

function buildSupplyFlight(
	side: Side,
	launch: string,
	consumer: string,
	consumerPos: WorldPoint,
	commodity: Commodity,
	_producer: Producer,
	logFn: LogFunction,
): Group | undefined {
	const aircraft = config.C.types.aircraft[side];
	const launchKind = S.base_kind[launch];
	const consumerKind = S.base_kind[consumer];
	const useHelicopter =
		launchKind === "farp" ||
		launchKind === "fob" ||
		consumerKind === "farp" ||
		consumerKind === "fob";
	let aircraftType: string;
	if (useHelicopter) {
		aircraftType = aircraft.transport_heli;
	} else {
		S.supply_heavy_flag = !S.supply_heavy_flag;
		aircraftType =
			(S.supply_heavy_flag
				? aircraft.transport_fw_heavy
				: aircraft.transport_fw) ?? aircraft.transport_fw;
	}
	const category = useHelicopter
		? Group.Category.HELICOPTER
		: Group.Category.AIRPLANE;
	const country = config.C.countries[side];

	// taskgen.c:1676 refuses a task whose start keysite is the requester.
	if (launch === consumer) {
		cs.dbg(
			"supply",
			"%s supply build ABORT: launch == consumer %s (taskgen.c:1676) -> refund transport, retry",
			cs.SIDE_NAME[side],
			consumer,
		);
		return undefined;
	}

	const producer = installations.nearest_producer(side, commodity, consumerPos);
	if (producer === undefined) {
		cs.dbg(
			"supply",
			"%s supply build ABORT at %s: producer died before spawn -> refund transport, retry",
			cs.SIDE_NAME[side],
			launch,
		);
		return undefined;
	}
	if (!supply.deliver_crate(side, commodity)) {
		cs.dbg(
			"supply",
			"%s supply build ABORT at %s: %s crate gone before pick-up -> refund transport, retry",
			cs.SIDE_NAME[side],
			launch,
			commodity,
		);
		return undefined;
	}

	const airbase = Airbase.getByName(launch);
	let airbasePos: Vec3;
	let airbaseId: number | undefined;
	if (airbase !== undefined) {
		airbasePos = airbase.getPosition().p;
		airbaseId = airbase.getID();
	} else {
		if (!useHelicopter) {
			supply.refund_crate(side, commodity);
			cs.dbg(
				"supply",
				"%s supply build ABORT: fixed-wing launch %s has no Airbase (no runway) -> crate refunded",
				cs.SIDE_NAME[side],
				launch,
			);
			return undefined;
		}
		const basePos = S.base_pos[launch];
		if (basePos === undefined) {
			supply.refund_crate(side, commodity);
			cs.dbg(
				"supply",
				"%s supply build ABORT: launch %s unknown (no Airbase, no base_pos) -> crate refunded",
				cs.SIDE_NAME[side],
				launch,
			);
			return undefined;
		}
		let groundHeight = 0;
		pcall(() => {
			groundHeight = land.getHeight({ x: basePos.x, y: basePos.z }) ?? 0;
		});
		airbasePos = { x: basePos.x, y: groundHeight, z: basePos.z };
	}

	const [baseX, baseY] = cs.wp_xy(airbasePos);
	const [producerX, producerY] = cs.wp_xy(producer.pos);
	const [consumerX, consumerY] = cs.wp_xy(consumerPos);
	const id = cs.next_id();
	const groupName = string.format(
		"Supply-%s-%s-%d-%d",
		string.sub(consumer, 1, 8),
		commodity,
		side,
		id,
	);
	const altitude = useHelicopter ? 150 : 3000;
	const altitudeType = useHelicopter ? "RADIO" : "BARO";
	const depart: WaypointData =
		airbaseId !== undefined
			? {
					type: "TakeOffParkingHot",
					action: "From Parking Area Hot",
					airdromeId: airbaseId,
					alt: airbasePos.y,
					alt_type: "BARO",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: baseX,
					y: baseY,
					name: "Depart",
					formation_template: "",
				}
			: {
					type: "TakeOffGroundHot",
					action: "From Ground Area Hot",
					alt: airbasePos.y,
					alt_type: "BARO",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: baseX,
					y: baseY,
					name: "Depart",
					formation_template: "",
				};
	const returnToBase: WaypointData =
		airbaseId !== undefined
			? {
					type: "Land",
					action: "Landing",
					airdromeId: airbaseId,
					alt: airbasePos.y,
					alt_type: "BARO",
					speed: SUPPLY_SPEED,
					ETA: 0,
					ETA_locked: false,
					x: baseX,
					y: baseY,
					name: "RTB",
					formation_template: "",
				}
			: {
					type: "Turning Point",
					action: "Turning Point",
					alt: altitude,
					alt_type: altitudeType,
					speed: SUPPLY_SPEED,
					ETA: 0,
					ETA_locked: false,
					x: baseX,
					y: baseY,
					name: "RTB",
					formation_template: "",
				};
	const groupData: GroupData = {
		name: groupName,
		task: "Transport",
		hidden: false,
		units: [
			{
				name: `${groupName}-1`,
				type: aircraftType,
				skill: "High",
				x: airbasePos.x,
				y: airbasePos.z,
				alt: airbasePos.y,
				alt_type: "BARO",
				speed: 0,
				heading: 0,
				payload: { fuel: useHelicopter ? 2200 : 12000 },
			},
		],
		route: {
			points: croute.expand(
				[
					depart,
					{
						type: "Turning Point",
						action: "Turning Point",
						alt: altitude,
						alt_type: altitudeType,
						speed: SUPPLY_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: producerX,
						y: producerY,
						name: "PickUp",
						formation_template: "",
					},
					{
						type: "Turning Point",
						action: "Fly Over Point",
						alt: altitude,
						alt_type: altitudeType,
						speed: SUPPLY_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: consumerX,
						y: consumerY,
						name: "DropOff",
						formation_template: "",
					},
					returnToBase,
				],
				side,
				{
					alt: altitude,
					alt_type: altitudeType,
					speed: SUPPLY_SPEED,
					name: "Nav",
				},
			),
		},
	};
	if (airbase !== undefined) {
		if (useHelicopter) {
			farpParking.configureDeparture(launch, airbase, groupData, depart);
			farpParking.configureLanding(launch, airbase, returnToBase);
		} else groupData.airdromeId = airbaseId;
	}

	const [spawned, group] = pcall(() =>
		coalition.addGroup(country, category, groupData),
	);
	if (spawned && group !== undefined) {
		supply.release_earmark(side, commodity);
		cs.register_task(groupName, {
			task_type: "supply",
			side,
			target_base: consumer,
			target_pos: consumerPos,
			commodity,
			launch_base: launch,
			born_time: timer.getTime(),
			producer_pos: { x: producer.pos.x, z: producer.pos.z },
			picked_up: false,
		});
		if (cs.escort_count("supply", side, airbasePos, consumerPos, logFn) > 0) {
			const [loaded, escort] = pcall(() => require<EscortModule>("heli_war"));
			if (loaded && escort !== undefined)
				pcall(() => escort.spawn_escort(side, consumerPos, logFn));
		}
		scheduleBackstop(
			groupName,
			launch,
			group,
			airbasePos,
			producer.pos,
			consumerPos,
		);
		logFn(
			string.format(
				"%s SUPPLY flight #%d: %s crate %s → %s (via producer %s, %s)",
				cs.SIDE_NAME[side],
				id,
				commodity,
				launch,
				consumer,
				producer.name,
				useHelicopter ? "heli" : "fixed-wing",
			),
		);
		cs.dbg(
			"supply",
			"%s supply flight %s DISPATCHED: %s pick-up @ %s -> drop @ %s, RTB %s (%s)",
			cs.SIDE_NAME[side],
			groupName,
			commodity,
			producer.name,
			consumer,
			launch,
			aircraftType,
		);
		return group;
	}

	supply.refund_crate(side, commodity);
	cs.dbg(
		"supply",
		"%s supply flight SPAWN FAILED from %s -> %s (%s): crate refunded, pcall_ok=%s err=%s",
		cs.SIDE_NAME[side],
		launch,
		consumer,
		aircraftType,
		tostring(spawned),
		tostring(group),
	);
	return undefined;
}

export function request(
	side: Side,
	consumer: string,
	commodity: Commodity,
	logFn: LogFunction = () => undefined,
): boolean {
	const consumerPos = S.base_pos[consumer];
	if (consumerPos === undefined || has_pending(side, consumer, commodity))
		return false;
	const producer = installations.nearest_producer(side, commodity, consumerPos);
	if (producer === undefined) {
		cs.dbg(
			"supply",
			"%s supply request for %s %s: NO live producer -> no flight (strangled)",
			cs.SIDE_NAME[side],
			consumer,
			commodity,
		);
		return false;
	}
	if (!supply.free_crate(side, commodity)) {
		cs.dbg(
			"supply",
			"%s supply request for %s %s: no crate banked -> no flight",
			cs.SIDE_NAME[side],
			consumer,
			commodity,
		);
		return false;
	}
	supply.earmark_crate(side, commodity);
	board.create_task({
		type: "supply",
		side,
		count: 1,
		log_fn: logFn,
		exclude_target_base: true,
		target: {
			base: consumer,
			pos: consumerPos,
			commodity,
			producer_name: producer.name,
			producer_pos: producer.pos,
			objective: { kind: "keysite", base: consumer },
		},
		builder: (launch: string) =>
			buildSupplyFlight(
				side,
				launch,
				consumer,
				consumerPos,
				commodity,
				producer,
				logFn,
			),
	});
	cs.dbg(
		"supply",
		"%s supply task QUEUED: %s %s (producer %s)",
		cs.SIDE_NAME[side],
		consumer,
		commodity,
		producer.name,
	);
	return true;
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
function scanSide(side: Side, logFn: LogFunction): void {
	const groups = coalition.getGroups(side);
	if (groups === undefined) return;
	for (const group of groups) {
		if (group === undefined || !group.isExist()) continue;
		const groupName = group.getName();
		if (
			!matches(groupName, `^${SUPPLY_PREFIX}%-`) ||
			S.supply_delivered[groupName]
		) {
			continue;
		}
		const task = cs.get_task(groupName);
		if (task === undefined || task.task_type !== "supply") continue;
		const consumer = task.target_base;
		const commodity = task.commodity;
		if (
			consumer === undefined ||
			(commodity !== "ammo" && commodity !== "fuel")
		)
			continue;
		const consumerPos = S.base_pos[consumer];
		const unit = group.getUnit(1);
		if (consumerPos === undefined || unit === undefined || !unit.isExist())
			continue;
		const position = unit.getPosition().p;
		if (!task.picked_up && task.producer_pos !== undefined) {
			const producerDx = position.x - task.producer_pos.x;
			const producerDz = position.z - task.producer_pos.z;
			const producerDistanceSquared =
				producerDx * producerDx + producerDz * producerDz;
			if (producerDistanceSquared <= DELIVERY_RADIUS * DELIVERY_RADIUS) {
				task.picked_up = true;
				cs.dbg(
					"supply",
					"%s supply flight %s PICK-UP confirmed at producer (%.0fm)",
					cs.SIDE_NAME[side],
					groupName,
					math.sqrt(producerDistanceSquared),
				);
			}
		}
		const dx = position.x - consumerPos.x;
		const dz = position.z - consumerPos.z;
		const deliveryDistanceSquared = dx * dx + dz * dz;
		if (
			task.picked_up &&
			deliveryDistanceSquared <= DELIVERY_RADIUS * DELIVERY_RADIUS
		) {
			S.supply_delivered[groupName] = true;
			if (S.base_owner[consumer] === side) {
				if (commodity === "ammo") S.base_ammo[consumer] = FULL_SUPPLY_PERCENT;
				else S.base_fuel[consumer] = FULL_SUPPLY_PERCENT;
				logFn(
					string.format(
						"supply: %s %s delivered to %s → restocked to 100 (%s)",
						cs.SIDE_NAME[side],
						commodity,
						consumer,
						groupName,
					),
				);
				cs.dbg(
					"supply",
					"%s supply flight %s reached %s (%.0fm): %s restocked to 100%% — RTB",
					cs.SIDE_NAME[side],
					groupName,
					consumer,
					math.sqrt(deliveryDistanceSquared),
					commodity,
				);
			} else {
				cs.dbg(
					"supply",
					"%s supply flight %s reached %s but it flipped enemy — crate lost, no restock",
					cs.SIDE_NAME[side],
					groupName,
					consumer,
				);
			}
		}
	}
}

export function check_arrivals(logFn: LogFunction = () => undefined): void {
	for (const side of SIDES) scanSide(side, logFn);
}

export function schedule_arrivals(logFn: LogFunction = () => undefined): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"supply",
		"supply-flight arrival scanner REGISTERED period=%.0fs",
		ARRIVAL_SCAN_PERIOD,
	);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => check_arrivals(logFn));
			if (!ok) logFn(`supply_flight arrival scan error: ${tostring(error)}`);
			return time + ARRIVAL_SCAN_PERIOD;
		},
		undefined,
		timer.getTime() + ARRIVAL_SCAN_PERIOD,
	);
}
