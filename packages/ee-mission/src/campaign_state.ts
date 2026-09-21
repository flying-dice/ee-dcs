/** @noSelfInFile */
/*
-- campaign_state.lua
-- Inspired by:
--   aphavoc/source/entity/special/session/session.c   SESSION root entity: elapsed_time, start_time
--   aphavoc/source/entity/special/session/ss_updt.c   session periodic update
--   aphavoc/source/entity/special/force/force.h       FORCE per-side: kills, losses, hardware counts
--   aphavoc/source/entity/special/force/fc_funcs.c    add/remove_from_force_info hardware registry
--   aphavoc/source/ai/highlevl/imaps.c                normalise_importance_imaps balance-of-power
--
-- Singleton state table for the entire campaign session.
-- All other modules require this and read/write M.S directly.
-- Mirrors SESSION (root) + FORCE (per-side) entity data.
*/
import type {
	CampaignState,
	Side,
	StatCategory,
	TaskInfo,
	TaskResult,
	TaskTermination,
	WorldPoint,
} from "./campaign_types";

export const MINIMUM_EFFICIENCY = 0.3; // eech ks_dbase.c; ks_float.c:285-291
export const HEALTH_NEUTRALISED = MINIMUM_EFFICIENCY;
export const HEALTH_DESTROYED = 0.0;
export const OBJECTIVES_PER_SIDE = 5; // highlevl/setup.c:79
// DCS adapter values: generated IDs start above the small IDs commonly used by authored mission objects.
const FIRST_DYNAMIC_ENTITY_ID = 2000;
// DCS adapter guard: life at or below one is treated as a dead/stale unit handle.
const MIN_LIVE_UNIT_LIFE = 1.0;
const PERCENT_SCALE = 100;
const PERCENT_ROUNDING_OFFSET = 0.5;
const BALANCED_FORCE_PERCENT = 50;
// task.c:364 applies the 0.8 minimum-efficiency success margin; the rating cutoffs are port policy.
const STRIKE_NEUTRALISED_MARGIN = 0.8;
const STRIKE_SUCCESS_RATING = 0.25;
const STRIKE_PARTIAL_RATING = 0.1;

_DMT_GEN = (_DMT_GEN ?? 0) + 1;
export const GENERATION = _DMT_GEN;
if (_DMT_DEBUG === undefined) _DMT_DEBUG = true;

export function dbg(
	tag: string,
	fmt: string,
	...args: Array<string | number | boolean | undefined>
): void {
	if (!_DMT_DEBUG) return;
	let rendered: string;
	try {
		rendered = string.format(fmt, ...args);
	} catch (_error) {
		rendered = `FMT-ERR ${fmt}`;
	}
	env.info(`[dmt:${tag}] ${rendered}`);
}

const freshStats = (): CampaignState["stats"][Side] => ({
	kills: {},
	losses: {},
	sorties: 0,
	tasks_created: 0,
	tasks_completed: 0,
	tasks_partial: 0,
	tasks_failed: 0,
});

export const S: CampaignState = {
	start_time: 0,
	game_over: false,
	base_health: {},
	base_owner: {},
	base_pos: {},
	base_efficiency: {},
	base_kind: {},
	objectives: {},
	strength: {
		[coalition.side.BLUE]: PERCENT_SCALE,
		[coalition.side.RED]: PERCENT_SCALE,
	},
	ground_groups: { [coalition.side.BLUE]: {}, [coalition.side.RED]: {} },
	arty_groups: { [coalition.side.BLUE]: {}, [coalition.side.RED]: {} },
	counter_battery: {},
	base_ledger: {},
	base_inflight: {},
	group_launch_base: {},
	force_current: {},
	base_idle_groups: {},
	active_tasks: {},
	board_tasks: [],
	board_failed: 0,
	farp_active: {},
	stats: {
		[coalition.side.BLUE]: freshStats(),
		[coalition.side.RED]: freshStats(),
	},
	pending_captures: {},
	imap: { raw: {}, nrm: {} },
	fow: {},
	keysites: {},
	pilots: {},
	spawn_queue: [],
	_spawn_seq: 0,
	_spawn_drain_reported: false,
	patrol_groups: {},
	regen_queue: {},
	production: {},
	base_ammo: {},
	base_fuel: {},
	base_warehouse: {},
	base_assign_toggle: {},
	base_last_strike: {},
	base_ad_groups: {},
	base_fp_groups: {},
	sec_groups: { [coalition.side.BLUE]: {}, [coalition.side.RED]: {} },
	keysite_assist_timer: {},
	supply_delivered: {},
	supply_heavy_flag: false,
	_completed: {},
	_recycled: {},
	_board_diag: {},
};

export const SIDE_NAME: Record<number, string> = {
	[coalition.side.BLUE]: "BLUE",
	[coalition.side.RED]: "RED",
};
export const ENEMY: Record<number, Side> = {
	[coalition.side.BLUE]: coalition.side.RED,
	[coalition.side.RED]: coalition.side.BLUE,
};

let sequence = FIRST_DYNAMIC_ENTITY_ID;
export function next_id(): number {
	sequence += 1;
	return sequence;
}

export function register_task(gname: string, info: TaskInfo): void {
	S.active_tasks[gname] = info;
	stat_sortie(info.side);
}
export function get_task(gname: string): TaskInfo | undefined {
	return S.active_tasks[gname];
}

export let task_end_hook: ((gname: string) => void) | undefined;
export function set_task_end_hook(
	hook: ((gname: string) => void) | undefined,
): void {
	task_end_hook = hook;
}
export function clear_task(gname: string): void {
	delete S.active_tasks[gname];
	if (task_end_hook) {
		try {
			task_end_hook(gname);
		} catch (_error) {
			/* map annotations must never block cleanup */
		}
	}
}
export function has_task_against(
	task_type: string,
	target_base: string,
	side: Side,
): boolean {
	for (const task of Object.values(S.active_tasks)) {
		if (
			task.task_type === task_type &&
			task.target_base === target_base &&
			task.side === side
		)
			return true;
	}
	return false;
}

// Mirrors force_info_current_hardware: live fielded mobile units, including players.
export function count_current_hardware(side: Side): number {
	let count = 0;
	for (const group of coalition.getGroups(side) ?? []) {
		if (!group || !group.isExist()) continue;
		for (const unit of group.getUnits() ?? []) {
			if (unit && unit.isExist() && unit.getLife() > MIN_LIVE_UNIT_LIFE)
				count += 1;
		}
	}
	return count;
}

// fc_updt.c:140-161 balance-of-power formula.
export function recalc_strength(): void {
	const blue = count_current_hardware(coalition.side.BLUE);
	const red = count_current_hardware(coalition.side.RED);
	S.force_current[coalition.side.BLUE] = blue;
	S.force_current[coalition.side.RED] = red;
	const total = blue + red;
	S.strength[coalition.side.BLUE] =
		total > 0
			? Math.floor((blue / total) * PERCENT_SCALE + PERCENT_ROUNDING_OFFSET)
			: BALANCED_FORCE_PERCENT;
	S.strength[coalition.side.RED] =
		total > 0
			? Math.floor((red / total) * PERCENT_SCALE + PERCENT_ROUNDING_OFFSET)
			: BALANCED_FORCE_PERCENT;
}

export function base_is_active(name: string): boolean {
	return S.base_kind[name] !== "farp" || S.farp_active[name] === true;
}

export const STAT_CATEGORIES: StatCategory[] = [
	"air",
	"heli",
	"ground",
	"ship",
	"structure",
	"other",
];

// Proxy for EECH group sub_type; kill event targets can already be cleaned handles.
export function unit_category(obj: DcsObject | undefined): StatCategory {
	if (!obj) return "other";
	try {
		const group = obj.getGroup !== undefined ? obj.getGroup() : undefined;
		const category = group?.getCategory();
		if (category === Group.Category.AIRPLANE) return "air";
		if (category === Group.Category.HELICOPTER) return "heli";
		if (category === Group.Category.GROUND) return "ground";
		if (category === Group.Category.SHIP) return "ship";
	} catch (_error) {
		/* fall through to attributes */
	}
	try {
		const attributes = obj.getDesc()?.attributes ?? {};
		if (attributes["Helicopters"]) return "heli";
		if (attributes["Air"] || attributes["Planes"]) return "air";
		if (attributes["Ships"]) return "ship";
		if (attributes["Ground Units"] || attributes["Vehicles"]) return "ground";
		if (attributes["Buildings"] || attributes["Fortifications"])
			return "structure";
	} catch (_error) {
		/* descriptor may be stale; category fallback remains independently usable */
	}
	try {
		if (obj.getCategory() === Object.Category.STATIC) return "structure";
	} catch (_error) {
		/* stale DCS handle */
	}
	return "other";
}

export function stat_kill(
	killer_side: Side | undefined,
	victim_side: Side | undefined,
	category: StatCategory = "other",
): void {
	if (killer_side !== undefined && S.stats[killer_side] !== undefined)
		S.stats[killer_side].kills[category] =
			(S.stats[killer_side].kills[category] ?? 0) + 1;
	if (victim_side !== undefined && S.stats[victim_side] !== undefined)
		S.stats[victim_side].losses[category] =
			(S.stats[victim_side].losses[category] ?? 0) + 1;
}
export function stat_sortie(side: Side): void {
	S.stats[side].sorties += 1;
}
export function stat_task_created(side: Side): void {
	S.stats[side].tasks_created += 1;
}
export function stat_task_result(side: Side, result: TaskResult): void {
	const stats = S.stats[side];
	if (result === "failure") stats.tasks_failed += 1;
	else if (result === "partial") stats.tasks_partial += 1;
	else stats.tasks_completed += 1;
}
function statTotal(values: Partial<Record<StatCategory, number>>): number {
	let total = 0;
	for (const value of Object.values(values)) total += value;
	return total;
}
export function stats_summary_line(): string {
	const b = S.stats[coalition.side.BLUE];
	const r = S.stats[coalition.side.RED];
	return string.format(
		"STATS kills B=%d R=%d | losses B=%d R=%d | tasks(ok/part/fail) B=%d/%d/%d R=%d/%d/%d | sorties B=%d R=%d",
		statTotal(b.kills),
		statTotal(r.kills),
		statTotal(b.losses),
		statTotal(r.losses),
		b.tasks_completed,
		b.tasks_partial,
		b.tasks_failed,
		r.tasks_completed,
		r.tasks_partial,
		r.tasks_failed,
		b.sorties,
		r.sorties,
	);
}
export function stats_text(): string {
	const byCategory = (
		values: Partial<Record<StatCategory, number>>,
	): string => {
		const parts: string[] = [];
		for (const category of STAT_CATEGORIES)
			if ((values[category] ?? 0) > 0)
				parts.push(`${category}:${values[category]}`);
		return parts.length > 0 ? parts.join(" ") : "none";
	};
	const block = (side: Side): string => {
		const value = S.stats[side];
		return string.format(
			"%s\n  kills %d (%s)\n  losses %d (%s)\n  sorties %d\n  tasks: created %d, done %d, partial %d, failed %d",
			SIDE_NAME[side],
			statTotal(value.kills),
			byCategory(value.kills),
			statTotal(value.losses),
			byCategory(value.losses),
			value.sorties,
			value.tasks_created,
			value.tasks_completed,
			value.tasks_partial,
			value.tasks_failed,
		);
	};
	return `=== CAMPAIGN STATS ===\n${block(coalition.side.BLUE)}\n${block(coalition.side.RED)}`;
}

// Faithful structural task.c:110-502 completion assessment.
export function assess_task(
	task: TaskInfo | undefined,
	terminated: TaskTermination,
): LuaMultiReturn<[TaskResult, number]> {
	const successEnd = terminated === "route_complete";
	if (task?.task_type === "ground_strike") {
		const base = task.target_base;
		const installationHealth = base ? S.keysites[base]?.health : undefined;
		const efficiencyAfter = base
			? (S.base_health[base] ?? installationHealth ?? 1.0)
			: 1.0;
		if (
			base &&
			(!base_is_active(base) ||
				efficiencyAfter < MINIMUM_EFFICIENCY * STRIKE_NEUTRALISED_MARGIN)
		)
			return $multi("success", 1.0);
		const rating = Math.max(
			0,
			Math.min(1, (task.eff_before ?? 1.0) - efficiencyAfter),
		);
		if (rating >= STRIKE_SUCCESS_RATING) return $multi("success", rating);
		if (rating >= STRIKE_PARTIAL_RATING || successEnd)
			return $multi("partial", rating);
		return $multi("failure", rating);
	}
	if (task?.task_type === "recon" || task?.task_type === "bda") {
		if (successEnd) return $multi("success", 1.0);
		return $multi("failure", 0.0);
	}
	if (successEnd) return $multi("success", 1.0);
	return $multi("failure", 0.0);
}

export function wp_xy(world_pos: WorldPoint): LuaMultiReturn<[number, number]> {
	return $multi(world_pos.x, world_pos.z);
}
export function dist2d(ax: number, az: number, bx: number, bz: number): number {
	const dx = ax - bx;
	const dz = az - bz;
	return Math.sqrt(dx * dx + dz * dz);
}
export function heading_to(
	ax: number,
	az: number,
	bx: number,
	bz: number,
): number {
	return Math.atan2(bz - az, bx - ax);
}
export function group_is_alive(group: Group | undefined): boolean {
	if (!group || !group.isExist()) return false;
	for (const unit of group.getUnits() ?? [])
		if (unit && unit.isExist()) return true;
	return false;
}

// DCS adapter search rings in metres, expanding to a 4 km fallback limit.
const SNAP_RADII_METRES = [200, 500, 1000, 2000, 4000];
const SNAP_BEARING_COUNT = 8;
function surfaceAt(x: number, z: number): land.SurfaceType | undefined {
	try {
		return land.getSurfaceType({ x, y: z });
	} catch (_error) {
		return undefined;
	}
}
function isDry(surface: land.SurfaceType | undefined): boolean {
	return (
		surface === land.SurfaceType.LAND ||
		surface === land.SurfaceType.ROAD ||
		surface === land.SurfaceType.RUNWAY
	);
}
export function snap_land(
	x: number,
	z: number,
	fx: number = x,
	fz: number = z,
): WorldPoint {
	const surface = surfaceAt(x, z);
	if (isDry(surface)) return { x, z };
	for (const radius of SNAP_RADII_METRES) {
		for (const bearing of $range(0, SNAP_BEARING_COUNT - 1)) {
			const angle = bearing * ((Math.PI * 2) / SNAP_BEARING_COUNT);
			const px = x + Math.cos(angle) * radius;
			const pz = z + Math.sin(angle) * radius;
			if (isDry(surfaceAt(px, pz))) {
				dbg(
					"snap",
					"moved (%.0f,%.0f) surf=%s -> land (%.0f,%.0f) r=%dm",
					x,
					z,
					tostring(surface),
					px,
					pz,
					radius,
				);
				return { x: px, z: pz };
			}
		}
	}
	dbg(
		"snap",
		"NO land within %dm of (%.0f,%.0f) surf=%s -> fallback (%.0f,%.0f)",
		SNAP_RADII_METRES[SNAP_RADII_METRES.length - 1],
		x,
		z,
		tostring(surface),
		fx,
		fz,
	);
	return { x: fx, z: fz };
}

export const ESCORT_CRITICAL = 6; // ts_dbase.h:156
export const ESCORT_THRESHOLD: Partial<Record<string, number>> = {
	ground_strike: 3,
	oca_strike: 3,
	sead: 5,
	troop_insertion: 3,
	supply: 6,
};
// DCS base-as-sector proxy: sample every 25 km and cap each threat component at five sectors.
const ESCORT_SECTOR_STEP_METRES = 25000;
const ESCORT_THREAT_COMPONENT_CAP = 5;
const ESCORT_CRITICAL_FLIGHT_COUNT = 2;
const ESCORT_STANDARD_FLIGHT_COUNT = 1;

export function route_difficulty(
	side: Side,
	from_pos?: WorldPoint,
	to_pos?: WorldPoint,
): LuaMultiReturn<[number, number, number]> {
	if (!from_pos || !to_pos) return $multi(0, 0, 0);
	const imap = require<typeof import("./imap")>("imap");
	const dx = to_pos.x - from_pos.x;
	const dz = to_pos.z - from_pos.z;
	const count = Math.max(
		1,
		Math.floor(Math.sqrt(dx * dx + dz * dz) / ESCORT_SECTOR_STEP_METRES),
	);
	const seen: Record<string, boolean> = {};
	let airThreats = 0;
	let enemySectors = 0;
	for (const i of $range(0, count)) {
		const fraction = i / count;
		const px = from_pos.x + dx * fraction;
		const pz = from_pos.z + dz * fraction;
		let best: string | undefined;
		let bestDistance = math.huge;
		for (const [name, pos] of Object.entries(S.base_pos)) {
			if (S.base_owner[name] === undefined) continue;
			const ex = px - pos.x;
			const ez = pz - pos.z;
			const distance = ex * ex + ez * ez;
			if (distance < bestDistance) {
				bestDistance = distance;
				best = name;
			}
		}
		if (best && !seen[best]) {
			seen[best] = true;
			const pos = S.base_pos[best];
			if (imap.get(side, imap.AIR_DEFENCE, pos) > 0) airThreats += 1;
			if (S.base_owner[best] !== side) enemySectors += 1;
		}
	}
	const difficulty =
		Math.min(airThreats, ESCORT_THREAT_COMPONENT_CAP) +
		Math.min(enemySectors, ESCORT_THREAT_COMPONENT_CAP);
	return $multi(difficulty, airThreats, enemySectors);
}

export function escort_count(
	task_type: string,
	side: Side,
	from_pos?: WorldPoint,
	to_pos?: WorldPoint,
	log_fn: (message: string) => void = () => undefined,
): number {
	const threshold = ESCORT_THRESHOLD[task_type];
	if (threshold === undefined) return 0;
	const [difficulty, airThreats, enemySectors] = route_difficulty(
		side,
		from_pos,
		to_pos,
	);
	const count =
		difficulty >= ESCORT_CRITICAL
			? ESCORT_CRITICAL_FLIGHT_COUNT
			: difficulty >= threshold
				? ESCORT_STANDARD_FLIGHT_COUNT
				: 0;
	log_fn(
		string.format(
			"escort assess %s %s: difficulty=%d (air=%d enemy=%d) threshold=%d -> %d",
			SIDE_NAME[side],
			task_type,
			difficulty,
			airThreats,
			enemySectors,
			threshold,
			count,
		),
	);
	return count;
}
