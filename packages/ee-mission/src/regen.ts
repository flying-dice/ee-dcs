/** @noSelfInFile */
/*
-- regen.lua
-- EECH source: aphavoc/source/entity/special/regen/rg_updt.c
--   update_server() line 160  — sleep-based tick, period = regen_frequency * modifier
--   regen_update()  line 199  — dequeue front entry if queue non-empty + keysite usable + reserve > 0
--   regen_queue_insert() line 763 — ring buffer; when full, oldest is overwritten (front advances)
--   regen_queue_use()    line 820 — pop front, consume reserve_hardware, spawn via
--                                   create_landing_faction_members()
-- EECH source: aphavoc/source/entity/special/regen/regen.h
--   REGEN_QUEUE_DEFAULT_SIZE = 5
--   REGEN_QUEUE_MINIMUM_SIZE = 5
--   REGEN_UPDATE_SLOW   = 1.5
--   REGEN_UPDATE_MEDIUM = 1.0   ← used by get_regen_frequency_difficulty_modifier()
--   REGEN_UPDATE_FAST   = 0.5
-- EECH source: aphavoc/source/entity/special/regen/regen.c line 335
--   get_regen_frequency_difficulty_modifier() returns REGEN_UPDATE_MEDIUM (1.0) always (medium only)
-- regen_frequency[side] is mission-data driven (parsgen.c:1519); proxy value: 60 s
-- regen_update blocked when: building not alive OR keysite NOT KEYSITE_STATE_USABLE
--   → DCS proxy: S.base_health[base] <= cs.HEALTH_NEUTRALISED
-- regen_update blocked when: reserve_count <= 0
--   → DCS proxy: supply.available(base, type) <= 0
-- CLUSTER 4: supply.available/consume are now the PER-BASE ledger (S.base_ledger), so a regenerated
-- airframe draws from — and is fielded at — its OWN home base's idle inventory (the exact base the
-- dead group is homed to via nearest_friendly), not a shared side pool. Force conservation with
-- location: regen at a base with no reserve of that role is blocked even if another base has some.
--
-- Types tracked (mirrors ENTITY_SUB_TYPE_REGEN_* enum used to classify dead entities):
--   REGEN_FIXED_WING  → "striker" (group name prefix "Strike-")
--   REGEN_FIXED_WING  → "escort"  (group name prefix "Escort-")
--   REGEN_HELICOPTER  → "heli"    (group name prefix "Heli-", "BDA-")
*/

import * as cs from "./campaign_state";
import type { RegenEntry, Side, WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as farpParking from "./farp_parking";
import * as keysite from "./keysite";
import { BLUE, RED } from "./sides";
import type { Role } from "./supply";
import * as supply from "./supply";

type RegenRole = Extract<Role, "striker" | "escort" | "heli">;
type LogFunction = (this: void, message: string) => void;
interface AircraftConfig {
	country: number;
	striker: string;
	escort: string;
	heli: string;
}

const S = cs.S;
const REGEN_QUEUE_DEFAULT_SIZE = 5; // regen.h
const REGEN_UPDATE_MEDIUM = 1.0; // regen.h
const REGEN_FREQUENCY_BASE = 60; // mission-data proxy, parsgen.c:1519
const REGEN_PERIOD = REGEN_FREQUENCY_BASE * REGEN_UPDATE_MEDIUM;
const MAX_REARMING_TIME_SCALING_FACTOR = 5; // en_suply.h:67
const PLAYER_LANDED_RADIUS = 2000;
const REGEN_SPEED = 0;
const FULL_SUPPLY_PERCENT = 100; // EECH supply/rearming levels are percentages.
const TYPES: RegenRole[] = ["striker", "escort", "heli"];
const SIDES: Side[] = [BLUE, RED];

const AC: Record<Side, AircraftConfig> = {
	[BLUE]: {
		country: config.C.countries[BLUE],
		striker: config.C.types.aircraft[BLUE].striker,
		escort: config.C.types.aircraft[BLUE].escort,
		heli: config.C.types.aircraft[BLUE].attack_heli,
	},
	[RED]: {
		country: config.C.countries[RED],
		striker: config.C.types.aircraft[RED].striker,
		escort: config.C.types.aircraft[RED].escort,
		heli: config.C.types.aircraft[RED].attack_heli,
	},
};

function rearmScale(level = FULL_SUPPLY_PERCENT): number {
	return (
		-((MAX_REARMING_TIME_SCALING_FACTOR - 1) / FULL_SUPPLY_PERCENT) * level +
		MAX_REARMING_TIME_SCALING_FACTOR
	);
}

function classifyGroup(name: string): RegenRole | undefined {
	const role = supply.classify_group(name);
	return role === "striker" || role === "escort" || role === "heli"
		? role
		: undefined;
}

function nearestFriendly(side: Side, pos: WorldPoint): string | undefined {
	let best: string | undefined;
	let bestDistanceSquared = math.huge;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side && (S.base_health[name] ?? 1) >= cs.HEALTH_NEUTRALISED) {
			const basePos = S.base_pos[name];
			if (basePos !== undefined) {
				const dx = pos.x - basePos.x;
				const dz = pos.z - basePos.z;
				const distanceSquared = dx * dx + dz * dz;
				if (distanceSquared < bestDistanceSquared) {
					bestDistanceSquared = distanceSquared;
					best = name;
				}
			}
		}
	}
	return best;
}

// rg_updt.c:307-339: delay regen if a non-AI member is landed at the keysite.
function playerLandedAt(baseName: string, side: Side): boolean {
	const basePos = S.base_pos[baseName];
	if (basePos === undefined) return false;
	const [ok, players] = pcall(() => coalition.getPlayers(side));
	if (!ok || players === undefined) return false;
	for (const unit of players) {
		let alive = false;
		pcall(() => {
			alive = unit !== undefined && unit.isExist();
		});
		if (!alive) continue;
		let inAir = true;
		const [airStateRead] = pcall(() => {
			inAir = unit.inAir();
		});
		if (airStateRead && !inAir) {
			const [positionRead, position] = pcall(() => unit.getPosition().p);
			if (
				positionRead &&
				position !== undefined &&
				cs.dist2d(position.x, position.z, basePos.x, basePos.z) <=
					PLAYER_LANDED_RADIUS
			) {
				return true;
			}
		}
	}
	return false;
}

export function init(logFn: LogFunction = () => undefined): void {
	S.regen_queue = {
		[BLUE]: { striker: [], escort: [], heli: [] },
		[RED]: { striker: [], escort: [], heli: [] },
	};
	logFn(
		string.format(
			"regen: queues initialised (REGEN_QUEUE_DEFAULT_SIZE=%d, period=%ds)",
			REGEN_QUEUE_DEFAULT_SIZE,
			REGEN_PERIOD,
		),
	);
	cs.dbg(
		"regen",
		"queues initialised: size=%d period=%ds",
		REGEN_QUEUE_DEFAULT_SIZE,
		REGEN_PERIOD,
	);
}

// rg_updt.c:763 ring-buffer behavior: overflow evicts the oldest pending entry.
function queueInsert(
	side: Side,
	role: RegenRole,
	baseName: string,
	aircraftType: string,
): LuaMultiReturn<[true, boolean]> {
	const queue = S.regen_queue[side][role];
	let evicted = false;
	if (queue.length >= REGEN_QUEUE_DEFAULT_SIZE) {
		queue.shift();
		evicted = true;
	}
	queue.push({
		base_name: baseName,
		aircraft_type: aircraftType,
		enqueued: timer.getTime(),
	});
	return $multi(true, evicted);
}

// keysite.c:1483-1517: capture reseeds default groups at the captured base.
export function queue_reseed(
	side: Side,
	baseName: string,
	helicopterCount = 0,
	fixedWingCount = 0,
	logFn: LogFunction = () => undefined,
): void {
	const queues = S.regen_queue[side];
	if (queues === undefined) return;
	const aircraft = AC[side];
	for (let index = 0; index < helicopterCount; index++) {
		queueInsert(side, "heli", baseName, aircraft?.heli ?? "AH-64D");
	}
	for (let index = 0; index < fixedWingCount; index++) {
		queueInsert(side, "striker", baseName, aircraft?.striker ?? "F-16C bl.52d");
	}
	logFn(
		string.format(
			"regen: capture reseed at %s (%s) +%d heli +%d fw queued",
			baseName,
			cs.SIDE_NAME[side] ?? "?",
			helicopterCount,
			fixedWingCount,
		),
	);
	cs.dbg(
		"regen",
		"capture reseed at %s (%s): +%d heli +%d fw queued",
		baseName,
		cs.SIDE_NAME[side] ?? "?",
		helicopterCount,
		fixedWingCount,
	);
}

export function make_dead_handler(
	logFn: LogFunction = () => undefined,
): DcsEventHandler {
	return {
		onEvent(event: DcsEvent): void {
			if (
				event.id !== world.event.S_EVENT_DEAD ||
				event.initiator === undefined
			)
				return;
			const object = event.initiator;
			if (object.getGroup === undefined) return;
			const [groupRead, group] = pcall(() => object.getGroup?.());
			if (!groupRead || group === undefined) return;

			const [playerRead, playerName] = pcall(() => object.getPlayerName?.());
			if (playerRead && playerName !== undefined) {
				cs.dbg(
					"regen",
					"dead unit is a player (%s) - no regen queue (players first-class)",
					playerName,
				);
				return;
			}

			const [nameRead, readName] = pcall(() => group.getName());
			const groupName = nameRead ? readName : undefined;
			if (groupName !== undefined) {
				const [dyingNameRead, dyingName] = pcall(() => object.getName());
				let anyAlive = false;
				const [unitsRead, units] = pcall(() => group.getUnits());
				if (unitsRead && units !== undefined) {
					for (const unit of units) {
						if (
							unit !== undefined &&
							unit.isExist() &&
							(!dyingNameRead || unit.getName() !== dyingName)
						) {
							anyAlive = true;
							break;
						}
					}
				}
				if (!anyAlive) keysite.release_slot(groupName);
			}

			if (!group.isExist() || groupName === undefined || groupName === "")
				return;
			const role = classifyGroup(groupName);
			if (role === undefined) return;
			const unit = group.getUnit(1);
			if (unit === undefined || !unit.isExist()) return;
			const coalitionId = unit.getCoalition();
			if (coalitionId !== BLUE && coalitionId !== RED) return;
			const side: Side = coalitionId;
			const home = nearestFriendly(side, unit.getPosition().p);
			if (home === undefined) {
				logFn(
					string.format(
						"regen: dead %s — no friendly base found, skipped",
						groupName,
					),
				);
				cs.dbg(
					"regen",
					"%s dead, NO friendly base found for regen -> dropped (type=%s)",
					groupName,
					role,
				);
				return;
			}
			const aircraftType = AC[side]?.[role] ?? "F-16C bl.52d";
			if (S.regen_queue[side] === undefined) return;
			const [, evicted] = queueInsert(side, role, home, aircraftType);
			logFn(
				string.format(
					"regen: queued %s (%s) at %s [q=%d/%d]",
					groupName,
					role,
					home,
					S.regen_queue[side][role].length,
					REGEN_QUEUE_DEFAULT_SIZE,
				),
			);
			cs.dbg(
				"regen",
				"queue INSERT: %s (%s/%s) at %s [q=%d/%d]",
				groupName,
				cs.SIDE_NAME[side],
				role,
				home,
				S.regen_queue[side][role].length,
				REGEN_QUEUE_DEFAULT_SIZE,
			);
			if (evicted) {
				logFn(
					string.format(
						"regen: queue was full for %s/%s — oldest pending regen evicted",
						cs.SIDE_NAME[side],
						role,
					),
				);
				cs.dbg(
					"regen",
					"queue OVERFLOW %s/%s: oldest pending regen evicted (tempo loss)",
					cs.SIDE_NAME[side],
					role,
				);
			}
		},
	};
}

function spawnRegen(
	side: Side,
	role: RegenRole,
	entry: RegenEntry,
	logFn: LogFunction,
): boolean {
	const baseName = entry.base_name;
	const aircraftType = entry.aircraft_type;
	const aircraft = AC[side];
	if (aircraft === undefined) return false;
	const health = S.base_health[baseName] ?? 0;
	if (health < cs.HEALTH_NEUTRALISED) {
		logFn(
			string.format(
				"regen: %s too damaged (%.0f%%) — regen blocked",
				baseName,
				health * FULL_SUPPLY_PERCENT,
			),
		);
		cs.dbg(
			"regen",
			"spawn BLOCKED: %s too damaged (%.0f%% < neutralised threshold %.0f%%)",
			baseName,
			health * FULL_SUPPLY_PERCENT,
			cs.HEALTH_NEUTRALISED * FULL_SUPPLY_PERCENT,
		);
		return false;
	}
	if (supply.available(baseName, role) <= 0) {
		logFn(
			string.format(
				"regen: no %s reserve at %s — regen blocked",
				role,
				baseName,
			),
		);
		cs.dbg("regen", "spawn BLOCKED: no %s reserve at %s", role, baseName);
		return false;
	}
	if (playerLandedAt(baseName, side)) {
		logFn(
			string.format(
				"regen: human player landed at %s — regen delayed",
				baseName,
			),
		);
		cs.dbg(
			"regen",
			"spawn VETOED: human player landed within %.0fm of %s — regen delayed (retry next tick)",
			PLAYER_LANDED_RADIUS,
			baseName,
		);
		return false;
	}

	const airbase = Airbase.getByName(baseName);
	let airbasePos: Vec3;
	let airbaseId: AirbaseId | undefined;
	if (airbase !== undefined) {
		airbasePos = airbase.getPosition().p;
		airbaseId = airbase.getID();
	} else {
		const basePos = S.base_pos[baseName];
		if (basePos === undefined) {
			cs.dbg(
				"regen",
				"spawn BLOCKED: %s has no Airbase and no base_pos",
				baseName,
			);
			return false;
		}
		let groundHeight = 0;
		pcall(() => {
			groundHeight = land.getHeight({ x: basePos.x, y: basePos.z }) ?? 0;
		});
		airbasePos = { x: basePos.x, y: groundHeight, z: basePos.z };
	}

	supply.consume(baseName, role, 1);
	const [baseX, baseY] = cs.wp_xy(airbasePos);
	const id = cs.next_id();
	const prefix =
		role === "striker"
			? "Regen-Strike"
			: role === "escort"
				? "Regen-Escort"
				: "Regen-Heli";
	const groupName = string.format("%s-%d", prefix, id);
	const category =
		role === "heli" ? Group.Category.HELICOPTER : Group.Category.AIRPLANE;
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
	const groupData: GroupData = {
		name: groupName,
		task: role === "heli" ? "Transport" : "Ground Attack",
		hidden: false,
		units: [
			{
				name: `${groupName}-1`,
				type: aircraftType,
				skill: "Good",
				x: airbasePos.x,
				y: airbasePos.z,
				alt: airbasePos.y,
				alt_type: "BARO",
				speed: REGEN_SPEED,
				heading: 0,
				payload: { fuel: 4000, flare: 60, chaff: 60, gun: 100 },
			},
		],
		route: { points: [depart] },
	};
	if (airbase !== undefined) {
		if (role === "heli")
			farpParking.configureDeparture(baseName, airbase, groupData, depart);
		else groupData.airdromeId = airbaseId;
	}
	const group = coalition.addGroup(aircraft.country, category, groupData);
	if (group !== undefined) {
		logFn(
			string.format(
				"regen: spawned %s %s at %s",
				groupName,
				aircraftType,
				baseName,
			),
		);
		cs.dbg(
			"regen",
			"spawn SUCCESS: %s (%s) at %s",
			groupName,
			aircraftType,
			baseName,
		);
		return true;
	}
	cs.dbg(
		"regen",
		"spawn FAILED: %s (%s) at %s (addGroup returned nil)",
		groupName,
		aircraftType,
		baseName,
	);
	return false;
}

function processQueue(side: Side, role: RegenRole, logFn: LogFunction): void {
	const queue = S.regen_queue[side][role];
	if (queue === undefined || queue.length === 0) return;
	const entry = queue[0];
	const supplyLevel = S.base_ammo[entry.base_name] ?? 100;
	const required = REGEN_PERIOD * rearmScale(supplyLevel);
	const waited = timer.getTime() - entry.enqueued;
	if (waited < required) return;
	cs.dbg(
		"regen",
		"dequeue attempt: %s/%s front=%s@%s (waited=%.0fs >= required=%.0fs, ammo=%.0f%%)",
		cs.SIDE_NAME[side],
		role,
		entry.aircraft_type,
		entry.base_name,
		waited,
		required,
		supplyLevel,
	);
	if (spawnRegen(side, role, entry, logFn)) queue.shift();
}

export function schedule_regen(logFn: LogFunction = () => undefined): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"regen",
		"scheduler REGISTERED offset=%.0fs period=%.0fs",
		REGEN_PERIOD,
		REGEN_PERIOD,
	);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => {
				for (const side of SIDES) {
					for (const role of TYPES) processQueue(side, role, logFn);
				}
			});
			if (!ok) logFn(`regen tick error: ${tostring(error)}`);
			return time + REGEN_PERIOD;
		},
		undefined,
		timer.getTime() + REGEN_PERIOD,
	);
}
