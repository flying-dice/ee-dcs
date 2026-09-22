/** @noSelfInFile */
/*
-- task_board.lua
-- EECH source:
--   aphavoc/source/entity/system/en_types/en_task.h   TASK_STATE_TYPES (UNASSIGNED/ASSIGNED/
--                                                      COMPLETED, :83-90), TASK_TERMINATED_TYPES
--                                                      (EXPIRE_TIME_REACHED, :115-127)
--   aphavoc/source/entity/special/task/task.c          task list membership / state machine
--                                                      (get_local_task_list_type :561-589)
--   aphavoc/source/entity/special/task/ts_updt.c        update_server: UNASSIGNED expire_timer
--                                                      countdown → TASK_TERMINATED (:99-124)
--   aphavoc/source/entity/special/task/ts_dbase.c       per-type task_priority / expiry defaults
--   aphavoc/source/ai/taskgen/assign.c                 assign_keysite_tasks (sort by priority,
--                                                      critical ×2, :201-212); get_suitable_
--                                                      registered_group (LOWEST-positive-suitability
--                                                      winner, best_result=FLT_MAX / result<best,
--                                                      :433-501, the quirk at :497); locality gate
--   aphavoc/source/ai/highlevl/suitable.c              group×task suitability matrix
--   aphavoc/source/entity/special/keysite/keysite.h    KEYSITE_TASK_ASSIGN_TIMER = 3 min (:69)
--
-- THE ASSIGNMENT ENGINE (Cluster 4). Shipped EECH does NOT spawn fresh aircraft per task: order
-- generation creates TASK entities and this engine matches them to EXISTING idle groups resident
-- at keysites. The port previously fresh-spawned per task (no unassigned pool, no suitability, no
-- failure path). This module restores the shipped model with a DCS-shaped ledger:
--
--   * Idle aircraft = a PER-BASE ledger (supply.lua S.base_ledger) — counts by role at each owned
--     base, a documented proxy for EECH's live aircraft parked at keysites (DCS cannot keep
--     hundreds of parked AI aircraft alive).
--   * Generators create_task(...) an UNASSIGNED record instead of spawning.
--   * tick() drains the board: sort by priority (critical ×2, assign.c:201-204); for each task pick
--     the suitable base inventory (SUIT matrix → role; assign.c:497 LOWEST-positive-suitability
--     winner reproduced exactly; distance a pass/fail gate, TASK-F14); consume that base's ledger;
--     physically spawn via the generator's builder; mark ASSIGNED. On spawn failure → refund the
--     ledger, task STAYS UNASSIGNED for retry until expiry (refund discipline).
--   * UNASSIGNED past its unassigned-expiry (ts_updt.c:99-124) → FAILED, removed — the real
--     task-failure path that the fresh-spawn port never had.
--
-- Dedup: while a task is UNASSIGNED the board keeps a synthetic marker in S.active_tasks (keyed
-- "board:<id>", shaped {task_type,target_base,side}) so the existing cs.has_task_against() /
-- reaction dedup guards transparently see QUEUED-but-not-yet-spawned tasks. On assignment the
-- marker is dropped and the freshly spawned group registers under its real name (reaction's BIRTH
-- path). So a target is never double-tasked whether the prior task is queued or already flying.
--
-- Reaction unchanged: the ASSIGNED transition IS the DCS S_EVENT_BIRTH (the group is physically
-- created at assignment), and completion is RTB (S_EVENT_LAND) — exactly what reaction.lua already
-- keys off (ENTITY_MESSAGE_TASK_ASSIGNED / TASK_COMPLETED). The board owns create→assign→expire.
*/
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import * as ks from "./keysite";
import * as supply from "./supply";

const S = cs.S;
type LogFn = (message: string) => void;

import type { BoardRole, BoardTask, BoardTaskSpec } from "./campaign_types";
import { BLUE, RED } from "./sides";

export type {
	BoardRole,
	BoardTarget,
	BoardTask,
	BoardTaskSpec,
	BoardTaskState,
} from "./campaign_types";

interface CandidateBase {
	name: string;
	pos: WorldPoint;
	d: number;
	h: number;
}
interface Suitability {
	role: Exclude<BoardRole, "player">;
	s: number;
}
interface PilotModule {
	PLAYER_FLYABLE: Partial<Record<string, boolean>>;
}
interface OverlayModule {
	add_task_arrow(
		this: void,
		name: string,
		from: WorldPoint,
		to: WorldPoint,
		side: Side,
	): void;
}

const SECONDS_PER_MINUTE = 60;
const ASSIGN_CADENCE = 3 * SECONDS_PER_MINUTE;
export const PRIORITY: Record<string, number> = {
	ground_strike: 9,
	oca_strike: 6,
	oca_sweep: 7,
	cas: 6,
	bai: 4,
	sead: 9,
	recon: 7,
	bda: 9,
	troop_insertion: 10,
	heli_escort: 7,
	supply: 4,
};
export const CRITICAL: Partial<Record<string, boolean>> = {
	oca_strike: true,
	oca_sweep: true,
	troop_insertion: true,
};
export const EXPIRY: Record<string, number> = {
	ground_strike: 40 * SECONDS_PER_MINUTE,
	oca_strike: 30 * SECONDS_PER_MINUTE,
	oca_sweep: 30 * SECONDS_PER_MINUTE,
	cas: 20 * SECONDS_PER_MINUTE,
	bai: 20 * SECONDS_PER_MINUTE,
	sead: 30 * SECONDS_PER_MINUTE,
	recon: 10 * SECONDS_PER_MINUTE,
	bda: 30 * SECONDS_PER_MINUTE,
	troop_insertion: 45 * SECONDS_PER_MINUTE,
	heli_escort: 10 * SECONDS_PER_MINUTE,
	supply: 20 * SECONDS_PER_MINUTE,
};
const UNASSIGNED_EXPIRY_DEFAULT = 10 * SECONDS_PER_MINUTE;
export const SUIT: Record<string, Suitability[]> = {
	ground_strike: [{ role: "striker", s: 1 }],
	oca_strike: [{ role: "striker", s: 1 }],
	cas: [{ role: "heli", s: 1 }],
	bai: [{ role: "heli", s: 1 }],
	sead: [{ role: "striker", s: 1 }],
	oca_sweep: [{ role: "escort", s: 1 }],
	recon: [{ role: "recon", s: 1 }],
	bda: [{ role: "heli", s: 1 }],
	troop_insertion: [{ role: "transport", s: 1 }],
	heli_escort: [{ role: "heli", s: 1 }],
	supply: [{ role: "transport", s: 1 }],
};
const CRUISE_SPEED: Record<string, number> = {
	striker: 220,
	escort: 220,
	recon: 300,
	heli: 55,
	transport: 100,
};
const CRUISE_SPEED_DEFAULT = 100;
const ASSIGN_BUDGET_PER_BASE = 3;
const MIN_IDLE: Record<string, number> = {
	heli: 2,
	striker: 1,
	escort: 1,
	recon: 0,
	transport: 0,
	vehicle: 0,
};
const RESERVE_TASK_COUNT = 2;
const METRES_PER_KILOMETRE = 1000;
const BOARD_DIAGNOSTIC_THROTTLE_SECONDS = 30;
const CRITICAL_PRIORITY_MULTIPLIER = 2; // assign.c:201-204

let assignCount: Record<string, number> = {};
let skipPass: Record<string, boolean> = {};
let playerFlyable: Partial<Record<string, boolean>> | undefined;
let taskSequence = 0;

function reachableDistanceBeforeExpiry(
	role: BoardRole,
	task: BoardTask,
): number {
	const window = task.expiry_t - timer.getTime();
	return window <= 0
		? 0
		: (CRUISE_SPEED[role] ?? CRUISE_SPEED_DEFAULT) * window;
}

function playerFlyableSet(): Partial<Record<string, boolean>> | undefined {
	if (playerFlyable !== undefined) return playerFlyable;
	const [ok, pilots] = pcall(() => require<PilotModule>("pilots"));
	if (ok && pilots !== undefined) playerFlyable = pilots.PLAYER_FLYABLE;
	return playerFlyable;
}

function nextTaskId(): number {
	taskSequence += 1;
	return taskSequence;
}

function ownedBases(side: Side, pos?: WorldPoint): CandidateBase[] {
	const out: CandidateBase[] = [];
	for (const [name, owner] of Object.entries(S.base_owner)) {
		if (owner !== side || skipPass[name] || !cs.base_is_active(name)) continue;
		const health = S.base_health[name] ?? 1;
		const basePos = S.base_pos[name];
		if (health < cs.HEALTH_NEUTRALISED || basePos === undefined) continue;
		const distance =
			pos === undefined ? 0 : cs.dist2d(pos.x, pos.z, basePos.x, basePos.z);
		out.push({ name, pos: basePos, d: distance, h: health });
	}
	out.sort(pos !== undefined ? (a, b) => a.d - b.d : (a, b) => b.h - a.h);
	return out;
}

export function create_task(spec: BoardTaskSpec): BoardTask {
	const id = nextTaskId();
	const now = timer.getTime();
	const task: BoardTask = {
		id,
		type: spec.type,
		side: spec.side,
		target: spec.target ?? {},
		count: spec.count ?? 1,
		builder: spec.builder,
		log_fn: spec.log_fn ?? (() => undefined),
		origin: spec.origin ?? spec.type,
		priority: spec.priority ?? PRIORITY[spec.type] ?? 1,
		critical:
			spec.critical !== undefined
				? spec.critical
				: (CRITICAL[spec.type] ?? false),
		created_t: now,
		expiry_t:
			now + (spec.expiry ?? EXPIRY[spec.type] ?? UNASSIGNED_EXPIRY_DEFAULT),
		state: "UNASSIGNED",
		dedup_key: `board:${id}`,
		exclude_target_base: spec.exclude_target_base ?? false,
	};
	S.board_tasks.push(task);
	cs.stat_task_created(spec.side);
	S.active_tasks[task.dedup_key] = {
		task_type: task.type,
		target_base: task.target.base,
		side: task.side,
	};
	cs.dbg(
		"board",
		"created #%d %s side=%s target=%s prio=%.1f critical=%s expiry=%.0fmin immediate=%s",
		id,
		task.type,
		cs.SIDE_NAME[task.side],
		task.target.base ?? "field",
		task.priority,
		tostring(task.critical),
		(task.expiry_t - now) / SECONDS_PER_MINUTE,
		tostring(spec.immediate),
	);
	if (spec.immediate) try_assign(task);
	return task;
}

export function try_assign(task: BoardTask): boolean {
	if (task.state !== "UNASSIGNED") return false;
	const suitability = SUIT[task.type];
	if (suitability === undefined) return false;
	const targetPos = task.target.pos;
	const bases = ownedBases(task.side, targetPos);
	for (const entry of suitability) {
		if (entry.s <= 0) continue;
		const range = reachableDistanceBeforeExpiry(entry.role, task);
		let bestBase: string | undefined;
		let bestSuitability = math.huge;
		for (const candidate of bases) {
			let within = targetPos === undefined || candidate.d <= range;
			if (task.exclude_target_base && candidate.name === task.target.base)
				within = false;
			const need = task.count + (MIN_IDLE[entry.role] ?? 0);
			if (
				within &&
				(assignCount[candidate.name] ?? 0) < ASSIGN_BUDGET_PER_BASE &&
				ks.slot_available(candidate.name) >= 1 &&
				supply.ledger(candidate.name, entry.role) >= need &&
				entry.s < bestSuitability
			) {
				bestSuitability = entry.s;
				bestBase = candidate.name;
			}
		}
		if (bestBase === undefined && !task._dbg_logged) {
			let inRange = 0;
			let stocked = 0;
			let slots = 0;
			let budget = 0;
			const need = task.count + (MIN_IDLE[entry.role] ?? 0);
			for (const candidate of bases) {
				if (targetPos === undefined || candidate.d <= range) inRange += 1;
				if (supply.ledger(candidate.name, entry.role) >= need) stocked += 1;
				if (ks.slot_available(candidate.name) >= 1) slots += 1;
				if ((assignCount[candidate.name] ?? 0) < ASSIGN_BUDGET_PER_BASE)
					budget += 1;
			}
			task._dbg_logged = true;
			cs.dbg(
				"board",
				"%s %s vs %s UNASSIGNED (role=%s): owned_bases=%d in_range=%d(<=%.0fkm) stocked=%d free_slot=%d w/budget=%d",
				cs.SIDE_NAME[task.side],
				task.type,
				task.target.base ?? "field",
				entry.role,
				bases.length,
				inRange,
				range / METRES_PER_KILOMETRE,
				stocked,
				slots,
				budget,
			);
		}
		if (
			bestBase !== undefined &&
			supply.consume_base(bestBase, entry.role, task.count)
		) {
			const [ok, group] = pcall(() => task.builder(bestBase));
			if (ok && group !== undefined) {
				task.state = "ASSIGNED";
				task.role = entry.role;
				task.base = bestBase;
				const [nameOk, name] = pcall(() => group.getName());
				task.assigned_group = nameOk ? name : undefined;
				if (task.assigned_group !== undefined) {
					ks.reserve_slot(bestBase, task.assigned_group);
					// Some specialised builders register themselves because they carry extra
					// lifecycle data. Generic CAS/BAI/heli builders do not, so preserve the
					// board assignment as the authoritative active task when needed. This
					// also gives the F10 picture a stable mission label after the board entry
					// changes from queued to assigned.
					if (cs.get_task(task.assigned_group) === undefined)
						cs.register_task(task.assigned_group, {
							task_type: task.type,
							side: task.side,
							target_base: task.target.base,
							target_pos: task.target.pos,
							objective: task.target.objective ?? {
								kind: task.target.group ? "group" : "keysite",
								base: task.target.base,
								group: task.target.group,
								pos: task.target.pos,
							},
							born_time: timer.getTime(),
							role: entry.role,
							launch_base: bestBase,
							commodity: task.target.commodity,
							producer_pos: task.target.producer_pos,
						});
				}
				assignCount[bestBase] = (assignCount[bestBase] ?? 0) + 1;
				delete S.active_tasks[task.dedup_key];
				cs.dbg(
					"board",
					"#%d %s vs %s ASSIGNED base=%s role=%s group=%s (waited %.0fs)",
					task.id,
					task.type,
					task.target.base ?? "field",
					bestBase,
					entry.role,
					tostring(task.assigned_group),
					timer.getTime() - task.created_t,
				);
				return true;
			}
			supply.recycle_base(bestBase, entry.role, task.count);
			if (!ok) task.log_fn(`task_board builder error: ${tostring(group)}`);
			cs.dbg(
				"board",
				"#%d %s vs %s builder FAILED at base=%s role=%s ok=%s -> refunded, retry",
				task.id,
				task.type,
				task.target.base ?? "field",
				bestBase,
				entry.role,
				tostring(ok),
			);
			return false;
		}
	}
	if (CRITICAL[task.type] && suitability[0] !== undefined) {
		const role = suitability[0].role;
		const range = reachableDistanceBeforeExpiry(role, task);
		let inRange = 0;
		let slotted = 0;
		let stocked = 0;
		for (const base of bases) {
			if (targetPos === undefined || base.d <= range) {
				inRange += 1;
				if (ks.slot_available(base.name) >= 1) {
					slotted += 1;
					if (
						supply.ledger(base.name, role) >=
						task.count + (MIN_IDLE[role] ?? 0)
					)
						stocked += 1;
				}
			}
		}
		if (
			timer.getTime() - (S._board_diag[task.type] ?? 0) >
			BOARD_DIAGNOSTIC_THROTTLE_SECONDS
		) {
			S._board_diag[task.type] = timer.getTime();
			task.log_fn(
				string.format(
					"board: %s vs %s UNASSIGNED — %d owned, %d in-range, %d w/slot, %d w/%s-stock",
					task.type,
					task.target.base ?? "?",
					bases.length,
					inRange,
					slotted,
					stocked,
					role,
				),
			);
			cs.dbg(
				"board",
				"CRITICAL STALL %s vs %s: %d owned, %d in-range, %d w/slot, %d w/%s-stock",
				task.type,
				task.target.base ?? "?",
				bases.length,
				inRange,
				slotted,
				stocked,
				role,
			);
		}
	}
	return false;
}

export function assign_to_player(
	task: BoardTask | undefined,
	groupName: string | undefined,
	_groupId?: number,
): boolean {
	if (
		task === undefined ||
		task.state !== "UNASSIGNED" ||
		groupName === undefined
	)
		return false;
	task.state = "ASSIGNED";
	task.assigned_group = groupName;
	task.role = "player";
	task.player = true;
	delete S.active_tasks[task.dedup_key];
	cs.register_task(groupName, {
		task_type: task.type,
		side: task.side,
		target_base: task.target.base,
		target_pos: task.target.pos,
		objective: task.target.objective ?? {
			kind: "keysite",
			base: task.target.base,
		},
		born_time: timer.getTime(),
		player: true,
	});
	pcall(() => {
		const targetPos = task.target.pos;
		if (targetPos === undefined) return;
		const unit = Group.getByName(groupName)?.getUnit(1);
		if (unit?.isExist()) {
			const pos = unit.getPosition().p;
			require<OverlayModule>("map_overlay").add_task_arrow(
				groupName,
				{ x: pos.x, z: pos.z },
				targetPos,
				task.side,
			);
		}
	});
	cs.dbg(
		"board",
		"#%d %s vs %s ASSIGNED to PLAYER group=%s (left AI pool, no ledger/slot)",
		task.id,
		task.type,
		task.target.base ?? "field",
		groupName,
	);
	return true;
}

export function tick(logFn: LogFn = () => undefined): void {
	const now = timer.getTime();
	assignCount = {};
	skipPass = {};
	let skipped = 0;
	for (const [name, owner] of Object.entries(S.base_owner)) {
		if (owner !== BLUE && owner !== RED) continue;
		if ((S.base_health[name] ?? 1) >= 1) delete S.base_assign_toggle[name];
		else {
			const skip = !S.base_assign_toggle[name];
			S.base_assign_toggle[name] = skip;
			if (skip) {
				skipPass[name] = true;
				skipped += 1;
			}
		}
	}
	if (skipped > 0)
		cs.dbg(
			"board",
			"assign-interval ×2: %d non-USABLE base(s) skipped this pass (ks_updt.c:118-123)",
			skipped,
		);
	const live: BoardTask[] = [];
	for (const task of S.board_tasks) {
		if (task.state !== "UNASSIGNED") continue;
		if (now > task.expiry_t) {
			task.state = "FAILED";
			delete S.active_tasks[task.dedup_key];
			S.board_failed += 1;
			logFn(
				string.format(
					"task_board: %s vs %s EXPIRED after %.0fmin unassigned → FAILED (no suitable idle group)",
					task.type,
					task.target.base ?? "field",
					(now - task.created_t) / SECONDS_PER_MINUTE,
				),
			);
			cs.dbg(
				"board",
				"#%d %s vs %s EXPIRED after %.0fmin -> FAILED (total board_failed=%d)",
				task.id,
				task.type,
				task.target.base ?? "field",
				(now - task.created_t) / SECONDS_PER_MINUTE,
				S.board_failed,
			);
		} else live.push(task);
	}
	live.sort(
		(a, b) =>
			b.priority * (b.critical ? CRITICAL_PRIORITY_MULTIPLIER : 1) -
			a.priority * (a.critical ? CRITICAL_PRIORITY_MULTIPLIER : 1),
	);
	let humansPresent = false;
	for (const side of [BLUE, RED]) {
		const [ok, players] = pcall(() => coalition.getPlayers(side));
		if (ok && players !== undefined && players.length > 0) {
			humansPresent = true;
			break;
		}
	}
	let reserveLeft = humansPresent ? RESERVE_TASK_COUNT : 0;
	const flyable = playerFlyableSet();
	for (const task of live) {
		const reservable =
			reserveLeft > 0 &&
			flyable?.[task.type] === true &&
			!task.critical &&
			task.expiry_t - now > ASSIGN_CADENCE;
		if (reservable) {
			reserveLeft -= 1;
			cs.dbg(
				"board",
				"reserved #%d %s vs %s for players (%d/%d reserve left, %.0fs to expiry)",
				task.id,
				task.type,
				task.target.base ?? "field",
				reserveLeft,
				RESERVE_TASK_COUNT,
				task.expiry_t - now,
			);
		} else {
			const [ok, error] = pcall(() => try_assign(task));
			if (!ok) logFn(`task_board assign error: ${tostring(error)}`);
		}
	}
	S.board_tasks = S.board_tasks.filter((task) => task.state === "UNASSIGNED");
}

export function schedule(logFn: LogFn = () => undefined): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"board",
		"scheduler REGISTERED cadence=%.0fs offset=%.0fs",
		ASSIGN_CADENCE,
		ASSIGN_CADENCE,
	);
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			cs.dbg(
				"board",
				"tick FIRE: %d unassigned queued before pass",
				S.board_tasks.length,
			);
			const [ok, error] = pcall(() => tick(logFn));
			if (!ok) logFn(`task_board tick error: ${tostring(error)}`);
			return time + ASSIGN_CADENCE;
		},
		undefined,
		timer.getTime() + ASSIGN_CADENCE,
	);
}
