/** @noSelfInFile */
/*
-- ground_forces.lua
-- EECH source:
--   aphavoc/source/ai/highlevl/highlevl.c   create_advance_and_retreat_tasks (12 min campaign,
--                                            highlevl.c:250): advances the best frontline group ONE
--                                            road-node toward the warmest reachable node; retreat
--                                            emerges when forward nodes are hostile (:505-543).
--   aphavoc/source/ai/highlevl/order.c       initialise_armoured_divisions: the frontline is a
--                                            STANDING set of ground groups (ground registry), grouped
--                                            into divisions (ceil(count/12)) — NOT one column.
--   aphavoc/source/ai/faction/faction.c      initialise_frontline_forces (:1500-1662): places PRIMARY
--                                            (:1520-1562), SECONDARY (:1565-1600) and ARTILLERY
--                                            (:1602-1661) groups at road nodes. This module ports all
--                                            three: primary tank column (spawn_group), SP artillery
--                                            (spawn_arty_group), and the second-echelon SECONDARY group
--                                            (spawn_sec_group) behind each frontline base.
--   aphavoc/source/entity/special/group/group.h  GROUP.route_node, frontline_flag.
--
-- Port model: a STANDING FRONTLINE of N ground groups per side (one per frontline base), created at
-- OOB and drawn from the side's "vehicle" reserve. This replaces the old single-column-per-side.
-- Keysites are the movement "nodes": each group drives base-to-base toward the nearest enemy base,
-- retargets when its objective is captured, and retreats to the nearest friendly base when cut off.
--
-- STRUCTURAL LIMIT (documented, not a proxy we can close): DCS exposes no road-node adjacency graph,
-- so EECH's true node-by-node road pathfinding and "move one group one node per tick" discretisation
-- cannot be reproduced. Continuous vehicle movement between keysite nodes is the closest achievable;
-- the front paces itself through vehicle speed rather than a per-tick node step.
*/

import * as mode from "./campaign_mode";
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as supply from "./supply";

const S = cs.S;
type LogFn = (message: string) => void;
type Kind = "primary" | "arty" | "sec";
type SlotTable = string[][];

export interface SavedGroundSummary {
	name?: string;
	side: Side;
	kind: Kind;
	home_base: string;
	target_base?: string;
	n_alive?: number;
	want?: number;
	lead: WorldPoint;
}

const GND_PERIOD = mode.SCHED.ground.period; // highlevl.c:250 campaign / :224 skirmish
const COLUMN_SPEED_METRES_PER_SECOND = 8; // ≈ 29 km/h
// DCS adapter geometry in metres; EECH uses authored road nodes and formation components.
const ARTY_STANDOFF_METRES = 15000;
const FRONT_DIST = config.C.theatre.front_dist;
const CUTOFF_STRENGTH_FRACTION = 0.5;
const RETREAT_BASE_DISTANCE_METRES = 20000;
const PRIMARY_SPAWN_JITTER_METRES = 800;
const SUPPORT_SPAWN_JITTER_METRES = 200;
const ARTY_INITIAL_REAR_OFFSET_METRES = 1500;
const SECONDARY_STANDOFF_METRES = 10000;
const SECONDARY_INITIAL_REAR_OFFSET_METRES = 4000;
const ARTY_LATERAL_SLOT_SPACING_METRES = 2000;
const SECONDARY_LATERAL_SLOT_SPACING_METRES = 1500;
const DEPLOYMENT_SLOT_COUNT = 5;
const DEPLOYMENT_SLOT_CENTRE = 2;
const PRIMARY_UNIT_SPACING_X_METRES = 30;
const PRIMARY_UNIT_SPACING_Z_METRES = 15;
const ARTY_UNIT_SPACING_X_METRES = 35;
const PRIMARY_GROUP_BASE_SIZE = 7;
const PRIMARY_GROUP_SIZE_JITTER = 2;
const GROUPS_PER_FRONTLINE_BASE = 3;
const PERCENT_SCALE = 100;
const COUNTRY_OF = config.C.countries;
const SIDE_COL: Record<number, number> = {
	[coalition.side.BLUE]: 0,
	[coalition.side.RED]: 1,
};
const PRIMARY_SLOTS = config.C.types.ground.primary_slots;
const SECONDARY_SLOTS = config.C.types.ground.secondary_slots;
const ARTY_SLOTS = config.C.types.ground.arty_slots;
const MLRS_SLOTS = config.C.types.ground.mlrs_slots;
const ARTY_GROUP_SIZE = 4; // FORMCOMP.DAT:552/:569 :COUNT 4

interface Nearest {
	name?: string;
	distance: number;
}

function primaryGroupSize(): number {
	return Math.max(
		1,
		PRIMARY_GROUP_BASE_SIZE +
			math.random(-PRIMARY_GROUP_SIZE_JITTER, PRIMARY_GROUP_SIZE_JITTER),
	);
}
function composition(
	side: Side,
	slots: SlotTable,
	count = primaryGroupSize(),
): string[] {
	const out: string[] = [];
	const column = SIDE_COL[side];
	for (let i = 0; i < Math.min(count, slots.length); i += 1)
		out.push(slots[i][column]);
	return out;
}

function nearestBaseOf(ownerSide: Side, pos: WorldPoint): Nearest {
	let best: string | undefined;
	let bestDistance = math.huge;
	for (const [name, owner] of Object.entries(S.base_owner)) {
		const base = S.base_pos[name];
		if (owner !== ownerSide || base === undefined) continue;
		const distance = cs.dist2d(pos.x, pos.z, base.x, base.z);
		if (distance < bestDistance) {
			best = name;
			bestDistance = distance;
		}
	}
	return { name: best, distance: bestDistance };
}

function frontlineBases(side: Side): string[] {
	const result: string[] = [];
	const enemy = cs.ENEMY[side];
	for (const [name, owner] of Object.entries(S.base_owner)) {
		const pos = S.base_pos[name];
		if (owner !== side || pos === undefined) continue;
		for (const [enemyName, enemyOwner] of Object.entries(S.base_owner)) {
			const enemyPos = S.base_pos[enemyName];
			if (
				enemyOwner === enemy &&
				enemyPos !== undefined &&
				cs.dist2d(pos.x, pos.z, enemyPos.x, enemyPos.z) <= FRONT_DIST
			) {
				result.push(name);
				break;
			}
		}
	}
	return result;
}

function leadPosition(group: Group): WorldPoint | undefined {
	const unit = group.getUnit(1);
	return unit !== undefined && unit.isExist()
		? unit.getPosition().p
		: undefined;
}
function aliveFraction(group: Group, wanted: number): number {
	return wanted > 0 ? (group.getUnits()?.length ?? 0) / wanted : 0;
}

function route(
	group: Group,
	target: WorldPoint,
	terminalAction: "On Road" | "Off Road",
): void {
	const from = leadPosition(group);
	if (from === undefined) return;
	const mx = (from.x + target.x) * 0.5;
	const mz = (from.z + target.z) * 0.5;
	group.getController().setTask({
		id: "Mission",
		params: {
			route: {
				points: [
					{
						type: "Turning Point",
						action: "On Road",
						speed: COLUMN_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						alt: land.getHeight({ x: mx, y: mz }),
						alt_type: "BARO",
						x: mx,
						y: mz,
						name: "Via",
						formation_template: "",
					},
					{
						type: "Turning Point",
						action: terminalAction,
						speed: COLUMN_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						alt: land.getHeight({ x: target.x, y: target.z }),
						alt_type: "BARO",
						x: target.x,
						y: target.z,
						name: terminalAction === "On Road" ? "Objective" : "Deploy",
						formation_template: "",
					},
				],
			},
		},
	});
}

function spawnOrigin(
	side: Side,
	home: WorldPoint,
	rearOffset: number,
): WorldPoint {
	const enemy = nearestBaseOf(cs.ENEMY[side], home).name;
	const enemyPos = enemy !== undefined ? S.base_pos[enemy] : undefined;
	const ex = enemyPos?.x ?? home.x;
	const ez = enemyPos?.z ?? home.z + 1;
	const dx = home.x - ex;
	const dz = home.z - ez;
	const length = Math.max(Math.sqrt(dx * dx + dz * dz), 1);
	return cs.snap_land(
		home.x +
			(dx / length) * rearOffset +
			math.random(-SUPPORT_SPAWN_JITTER_METRES, SUPPORT_SPAWN_JITTER_METRES),
		home.z +
			(dz / length) * rearOffset +
			math.random(-SUPPORT_SPAWN_JITTER_METRES, SUPPORT_SPAWN_JITTER_METRES),
		home.x,
		home.z,
	);
}

function makeUnits(
	name: string,
	types: string[],
	start: WorldPoint,
	heading: number,
	artillery = false,
): UnitData[] {
	const units: UnitData[] = [];
	for (let index = 0; index < types.length; index += 1) {
		const x =
			start.x +
			index *
				(artillery
					? ARTY_UNIT_SPACING_X_METRES
					: PRIMARY_UNIT_SPACING_X_METRES);
		const z = start.z + index * (artillery ? 0 : PRIMARY_UNIT_SPACING_Z_METRES);
		units.push({
			name: `${name}-${index + 1}`,
			type: types[index],
			skill: "Average",
			x,
			y: z,
			alt: land.getHeight({ x, y: z }),
			alt_type: "BARO",
			heading,
		});
	}
	return units;
}

function spawnPrimary(
	side: Side,
	homeName: string,
	targetName: string,
	logFn: LogFn,
): boolean {
	if (!supply.consume_side(side, "vehicle", 1)) {
		logFn(`${cs.SIDE_NAME[side]} ground: vehicle reserve exhausted`);
		return false;
	}
	const home = S.base_pos[homeName];
	const target = S.base_pos[targetName];
	if (home === undefined || target === undefined) {
		supply.recycle_side(side, "vehicle", 1);
		return false;
	}
	const types = composition(side, PRIMARY_SLOTS);
	const id = cs.next_id();
	const name = string.format("GndCol-%d-%d", side, id);
	const start = cs.snap_land(
		home.x +
			math.random(-PRIMARY_SPAWN_JITTER_METRES, PRIMARY_SPAWN_JITTER_METRES),
		home.z +
			math.random(-PRIMARY_SPAWN_JITTER_METRES, PRIMARY_SPAWN_JITTER_METRES),
		home.x,
		home.z,
	);
	const units = makeUnits(
		name,
		types,
		start,
		cs.heading_to(start.x, start.z, target.x, target.z),
	);
	const middle = {
		x: (start.x + target.x) * 0.5,
		z: (start.z + target.z) * 0.5,
	};
	const [ok, group] = pcall(() =>
		coalition.addGroup(COUNTRY_OF[side], Group.Category.GROUND, {
			name,
			hidden: false,
			units,
			route: {
				points: [
					{
						type: "Turning Point",
						action: "On Road",
						speed: COLUMN_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						alt: land.getHeight({ x: start.x, y: start.z }),
						alt_type: "BARO",
						x: start.x,
						y: start.z,
						name: "Start",
						formation_template: "",
					},
					{
						type: "Turning Point",
						action: "On Road",
						speed: COLUMN_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						alt: land.getHeight({ x: middle.x, y: middle.z }),
						alt_type: "BARO",
						x: middle.x,
						y: middle.z,
						name: "Via",
						formation_template: "",
					},
					{
						type: "Turning Point",
						action: "On Road",
						speed: COLUMN_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						alt: land.getHeight({ x: target.x, y: target.z }),
						alt_type: "BARO",
						x: target.x,
						y: target.z,
						name: "Objective",
						formation_template: "",
					},
				],
			},
		}),
	);
	if (ok && group !== undefined) {
		S.ground_groups[side][name] = {
			grp: group,
			target_base: targetName,
			home_base: homeName,
			want: units.length,
		};
		logFn(
			string.format(
				"GndCol %s: %d units %s → %s",
				name,
				units.length,
				homeName,
				targetName,
			),
		);
		return true;
	}
	supply.recycle_side(side, "vehicle", 1);
	return false;
}

function spawnSupport(
	side: Side,
	homeName: string,
	kind: "arty" | "sec",
	useMlrs: boolean,
	logFn: LogFn,
): boolean {
	if (!supply.consume_side(side, "vehicle", 1)) return false;
	const home = S.base_pos[homeName];
	if (home === undefined) {
		supply.recycle_side(side, "vehicle", 1);
		return false;
	}
	const artillery = kind === "arty";
	const slots = artillery
		? useMlrs
			? MLRS_SLOTS
			: ARTY_SLOTS
		: SECONDARY_SLOTS;
	const types = composition(
		side,
		slots,
		artillery ? ARTY_GROUP_SIZE : primaryGroupSize(),
	);
	const id = cs.next_id();
	const name = string.format(
		artillery ? "Arty-%d-%d" : "GndSec-%d-%d",
		side,
		id,
	);
	const start = spawnOrigin(
		side,
		home,
		artillery
			? ARTY_INITIAL_REAR_OFFSET_METRES
			: SECONDARY_INITIAL_REAR_OFFSET_METRES,
	);
	const units = makeUnits(name, types, start, 0, artillery);
	const [ok, group] = pcall(() =>
		coalition.addGroup(COUNTRY_OF[side], Group.Category.GROUND, {
			name,
			hidden: false,
			units,
			route: {
				points: [
					{
						type: "Turning Point",
						action: "Off Road",
						speed: 0,
						ETA: 0,
						ETA_locked: true,
						alt: land.getHeight({ x: start.x, y: start.z }),
						alt_type: "BARO",
						x: start.x,
						y: start.z,
						name: "Hold",
						formation_template: "",
					},
				],
			},
		}),
	);
	if (ok && group !== undefined) {
		if (artillery)
			S.arty_groups[side][name] = { grp: group, home_base: homeName };
		else
			S.sec_groups[side][name] = {
				grp: group,
				home_base: homeName,
				want: units.length,
			};
		logFn(
			artillery
				? string.format(
						"Artillery %s: %d units (2×%s + truck + scout) at %s",
						name,
						units.length,
						types[0],
						homeName,
					)
				: string.format(
						"GndSec %s: %d units (2nd echelon) behind %s",
						name,
						units.length,
						homeName,
					),
		);
		return true;
	}
	supply.recycle_side(side, "vehicle", 1);
	return false;
}

export function init_oob(logFn: LogFn = () => undefined): void {
	S.ground_groups = { [coalition.side.BLUE]: {}, [coalition.side.RED]: {} };
	S.arty_groups = { [coalition.side.BLUE]: {}, [coalition.side.RED]: {} };
	S.sec_groups = { [coalition.side.BLUE]: {}, [coalition.side.RED]: {} };
	for (const side of [coalition.side.BLUE, coalition.side.RED] as Side[]) {
		const bases = frontlineBases(side);
		const demand = GROUPS_PER_FRONTLINE_BASE * bases.length;
		const have = supply.reserve_side(side, "vehicle");
		if (have < demand) supply.recycle_side(side, "vehicle", demand - have);
		let mlrs = false;
		for (const base of bases) {
			const target = nearestBaseOf(cs.ENEMY[side], S.base_pos[base]).name;
			if (target !== undefined) spawnPrimary(side, base, target, logFn);
			spawnSupport(side, base, "arty", mlrs, logFn);
			mlrs = !mlrs;
			spawnSupport(side, base, "sec", false, logFn);
		}
		logFn(
			string.format(
				"ground OOB: %s frontline = %d group(s) + %d artillery + %d secondary group(s)",
				cs.SIDE_NAME[side],
				Object.keys(S.ground_groups[side]).length,
				Object.keys(S.arty_groups[side]).length,
				Object.keys(S.sec_groups[side]).length,
			),
		);
	}
}

function nearestUnoccupiedEnemy(
	side: Side,
	pos: WorldPoint,
	occupied: Record<string, boolean>,
): string | undefined {
	const enemy = cs.ENEMY[side];
	let best: string | undefined;
	let bestDistance = math.huge;
	for (const [name, owner] of Object.entries(S.base_owner)) {
		const base = S.base_pos[name];
		if (owner !== enemy || occupied[name] || base === undefined) continue;
		const distance = cs.dist2d(pos.x, pos.z, base.x, base.z);
		if (distance < bestDistance) {
			best = name;
			bestDistance = distance;
		}
	}
	return best;
}

// TSTL/Lua-interop correctness fix — NOT a campaign constant, so there is deliberately no EECH
// citation. `string.match()` is a LuaMultiReturn; assigned to a single variable, typescript-to-lua
// emits `local match = {string.match(name, p)}` — a TABLE, so `tonumber(match)` is nil and this
// helper always returned 0. Every artillery/secondary group then took slot (0 % 5) - 2 = -2,
// collapsing the five-slot lateral dispersion onto one point. Destructuring forces the
// single-value form, matching the Lua baseline's `tonumber(sname:match("(%d+)$")) or 0`.
function numericSuffix(name: string): number {
	const [match] = string.match(name, "(%d+)$");
	return match !== undefined ? (tonumber(match) ?? 0) : 0;
}

function advanceRetreat(side: Side, logFn: LogFn): void {
	const groups = S.ground_groups[side];
	const enemy = cs.ENEMY[side];
	const covered: Record<string, boolean> = {};
	const occupied: Record<string, boolean> = {};
	let aliveCount = 0;
	let retreated = 0;
	let advanced = 0;
	for (const [name, record] of Object.entries(groups)) {
		if (!cs.group_is_alive(record.grp)) {
			delete groups[name];
			continue;
		}
		aliveCount += 1;
		covered[record.home_base] = true;
		if (
			record.target_base !== undefined &&
			S.base_owner[record.target_base] === enemy
		)
			occupied[record.target_base] = true;
	}
	for (const [name, record] of Object.entries(groups)) {
		const pos = leadPosition(record.grp);
		if (pos === undefined) continue;
		const strength = aliveFraction(record.grp, record.want ?? 4);
		const friendly = nearestBaseOf(side, pos);
		if (strength < CUTOFF_STRENGTH_FRACTION) {
			if (
				friendly.name !== undefined &&
				friendly.distance > RETREAT_BASE_DISTANCE_METRES &&
				record.target_base !== friendly.name
			) {
				record.target_base = friendly.name;
				route(record.grp, S.base_pos[friendly.name], "On Road");
				retreated += 1;
				logFn(
					string.format(
						"GndCol %s retreating → %s (str %.0f%%)",
						name,
						friendly.name,
						strength * PERCENT_SCALE,
					),
				);
			}
		} else if (
			record.target_base === undefined ||
			S.base_owner[record.target_base] !== enemy
		) {
			if (record.target_base !== undefined) delete occupied[record.target_base];
			const target = nearestUnoccupiedEnemy(side, pos, occupied);
			if (target !== undefined && record.target_base !== target) {
				record.target_base = target;
				occupied[target] = true;
				route(record.grp, S.base_pos[target], "On Road");
				advanced += 1;
				logFn(string.format("GndCol %s advancing → %s", name, target));
			}
		}
	}

	let artilleryMoved = 0;
	for (const [name, record] of Object.entries(S.arty_groups[side])) {
		if (!cs.group_is_alive(record.grp)) {
			delete S.arty_groups[side][name];
			continue;
		}
		const pos = leadPosition(record.grp);
		if (pos === undefined) continue;
		const nearest = nearestBaseOf(enemy, pos);
		const base =
			nearest.name !== undefined ? S.base_pos[nearest.name] : undefined;
		if (
			nearest.name === undefined ||
			base === undefined ||
			nearest.distance <= ARTY_STANDOFF_METRES ||
			record.moving_to === nearest.name
		)
			continue;
		const dx = base.x - pos.x;
		const dz = base.z - pos.z;
		const length = Math.max(Math.sqrt(dx * dx + dz * dz), 1);
		const slot =
			(numericSuffix(name) % DEPLOYMENT_SLOT_COUNT) - DEPLOYMENT_SLOT_CENTRE;
		const px = -dz / length;
		const pz = dx / length;
		const deploy = cs.snap_land(
			base.x -
				(dx / length) * ARTY_STANDOFF_METRES +
				px * slot * ARTY_LATERAL_SLOT_SPACING_METRES,
			base.z -
				(dz / length) * ARTY_STANDOFF_METRES +
				pz * slot * ARTY_LATERAL_SLOT_SPACING_METRES,
			pos.x,
			pos.z,
		);
		route(record.grp, deploy, "Off Road");
		record.moving_to = nearest.name;
		artilleryMoved += 1;
	}

	const front = frontlineBases(side);
	let secondariesMoved = 0;
	for (const [name, record] of Object.entries(S.sec_groups[side])) {
		if (!cs.group_is_alive(record.grp)) {
			delete S.sec_groups[side][name];
			continue;
		}
		const pos = leadPosition(record.grp);
		if (pos === undefined || front.length === 0) continue;
		let behind: string | undefined;
		let best = math.huge;
		for (const baseName of front) {
			const base = S.base_pos[baseName];
			const distance = cs.dist2d(pos.x, pos.z, base.x, base.z);
			if (distance < best) {
				best = distance;
				behind = baseName;
			}
		}
		if (behind === undefined || record.behind_base === behind) continue;
		const base = S.base_pos[behind];
		const enemyBase = nearestBaseOf(enemy, base).name;
		const enemyPos =
			enemyBase !== undefined ? S.base_pos[enemyBase] : undefined;
		const dx = base.x - (enemyPos?.x ?? base.x);
		const dz = base.z - (enemyPos?.z ?? base.z - 1);
		const length = Math.max(Math.sqrt(dx * dx + dz * dz), 1);
		const slot =
			(numericSuffix(name) % DEPLOYMENT_SLOT_COUNT) - DEPLOYMENT_SLOT_CENTRE;
		const px = -dz / length;
		const pz = dx / length;
		const deploy = cs.snap_land(
			base.x +
				(dx / length) * SECONDARY_STANDOFF_METRES +
				px * slot * SECONDARY_LATERAL_SLOT_SPACING_METRES,
			base.z +
				(dz / length) * SECONDARY_STANDOFF_METRES +
				pz * slot * SECONDARY_LATERAL_SLOT_SPACING_METRES,
			pos.x,
			pos.z,
		);
		route(record.grp, deploy, "Off Road");
		record.behind_base = behind;
		secondariesMoved += 1;
	}

	let reinforced = 0;
	for (const base of frontlineBases(side)) {
		if (covered[base]) continue;
		const target =
			nearestUnoccupiedEnemy(side, S.base_pos[base], occupied) ??
			nearestBaseOf(enemy, S.base_pos[base]).name;
		if (target === undefined || !spawnPrimary(side, base, target, logFn)) break;
		covered[base] = true;
		if (S.base_owner[target] === enemy) occupied[target] = true;
		reinforced += 1;
	}
	cs.dbg(
		"ground",
		"%s advance/retreat tick: %d alive, %d retreated, %d advanced, %d reinforced, %d arty advancing, %d secondary moved",
		cs.SIDE_NAME[side],
		aliveCount,
		retreated,
		advanced,
		reinforced,
		artilleryMoved,
		secondariesMoved,
	);
}

const KIND_SLOTS: Record<Kind, SlotTable> = {
	primary: PRIMARY_SLOTS,
	arty: ARTY_SLOTS,
	sec: SECONDARY_SLOTS,
};

export function respawn_saved(
	summary: SavedGroundSummary,
	_logFn: LogFn = () => undefined,
): boolean {
	if (
		(summary.side !== coalition.side.BLUE &&
			summary.side !== coalition.side.RED) ||
		summary.lead === undefined
	)
		return false;
	const slots = KIND_SLOTS[summary.kind];
	const side = summary.side;
	const count = Math.max(1, Math.min(summary.n_alive ?? 1, slots.length));
	const start = cs.snap_land(
		summary.lead.x,
		summary.lead.z,
		summary.lead.x,
		summary.lead.z,
	);
	const name =
		summary.name ??
		string.format("Gnd-%s-%d-%d", summary.kind, side, cs.next_id());
	const units = makeUnits(
		name,
		composition(side, slots, count),
		start,
		0,
		summary.kind === "arty",
	);
	const target =
		summary.target_base !== undefined
			? S.base_pos[summary.target_base]
			: undefined;
	const points: WaypointData[] = [];
	if (summary.kind === "primary" && target !== undefined) {
		const middle = {
			x: (start.x + target.x) * 0.5,
			z: (start.z + target.z) * 0.5,
		};
		points.push(
			{
				type: "Turning Point",
				action: "On Road",
				speed: COLUMN_SPEED_METRES_PER_SECOND,
				ETA: 0,
				ETA_locked: false,
				alt: land.getHeight({ x: start.x, y: start.z }),
				alt_type: "BARO",
				x: start.x,
				y: start.z,
				name: "Start",
				formation_template: "",
			},
			{
				type: "Turning Point",
				action: "On Road",
				speed: COLUMN_SPEED_METRES_PER_SECOND,
				ETA: 0,
				ETA_locked: false,
				alt: land.getHeight({ x: middle.x, y: middle.z }),
				alt_type: "BARO",
				x: middle.x,
				y: middle.z,
				name: "Via",
				formation_template: "",
			},
			{
				type: "Turning Point",
				action: "On Road",
				speed: COLUMN_SPEED_METRES_PER_SECOND,
				ETA: 0,
				ETA_locked: false,
				alt: land.getHeight({ x: target.x, y: target.z }),
				alt_type: "BARO",
				x: target.x,
				y: target.z,
				name: "Objective",
				formation_template: "",
			},
		);
	} else
		points.push({
			type: "Turning Point",
			action: "Off Road",
			speed: 0,
			ETA: 0,
			ETA_locked: true,
			alt: land.getHeight({ x: start.x, y: start.z }),
			alt_type: "BARO",
			x: start.x,
			y: start.z,
			name: "Hold",
			formation_template: "",
		});
	const [ok, group] = pcall(() =>
		coalition.addGroup(COUNTRY_OF[side], Group.Category.GROUND, {
			name,
			hidden: false,
			units,
			route: { points },
		}),
	);
	if (!ok || group === undefined) return false;
	if (summary.kind === "primary")
		S.ground_groups[side][name] = {
			grp: group,
			target_base: summary.target_base,
			home_base: summary.home_base,
			want: summary.want ?? count,
		};
	else if (summary.kind === "sec")
		S.sec_groups[side][name] = {
			grp: group,
			home_base: summary.home_base,
			want: summary.want ?? count,
		};
	else S.arty_groups[side][name] = { grp: group, home_base: summary.home_base };
	return true;
}

export function schedule_ground(
	side: Side,
	initialOffset: number,
	logFn: LogFn = () => undefined,
): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"ground",
		"%s scheduler REGISTERED offset=%.0fs period=%.0fs",
		cs.SIDE_NAME[side],
		initialOffset,
		GND_PERIOD,
	);
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => advanceRetreat(side, logFn));
			if (!ok) logFn(`ground error: ${tostring(error)}`);
			return time + GND_PERIOD;
		},
		undefined,
		timer.getTime() + initialOffset,
	);
}
