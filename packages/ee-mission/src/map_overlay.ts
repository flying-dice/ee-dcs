/** @noSelfInFile */
/* Coalition-scoped F10 operational picture. Friendly state is complete; enemy state is reduced
 * unless fog-of-war says the viewing coalition has current intelligence. */
import * as cs from "./campaign_state";
import type { BoardTask, Side, WorldPoint } from "./campaign_types";
import * as fow from "./fog_of_war";
import { BLUE, RED } from "./sides";

const S = cs.S;
const SIDES: Side[] = [BLUE, RED];
const UPDATE_PERIOD_SECONDS = 30,
	OVERLAY_INITIAL_DELAY_SECONDS = 5,
	HEALTH_BAR_SEGMENTS = 5,
	PERCENT_SCALE = 100,
	MARKUP_LINE_SOLID = 1,
	FRONT_MAX_HALF_LENGTH_METRES = 30000,
	FRONT_LENGTH_FACTOR = 0.35,
	OBJECTIVE_LABEL_OFFSET_METRES = 750;

interface IdPool {
	next: number;
	end: number;
	free: number[];
}
interface TextMark {
	id: number;
	text: string;
	pos: WorldPoint;
	side: Side;
}
interface DesiredText {
	text: string;
	pos: WorldPoint;
	side: Side;
}
interface LineMark {
	id: number;
	from: WorldPoint;
	to: WorldPoint;
	side: Side;
}
interface DesiredLine {
	from: WorldPoint;
	to: WorldPoint;
	side: Side;
	color: MarkupColor;
}
interface TaskArrow {
	lineId: number;
	labelId?: number;
}

// Disjoint, resettable blocks. Removed IDs are recycled and pools never wrap onto a live mark.
const TASK_LINE_POOL: IdPool = { next: 20000, end: 20399, free: [] };
const TASK_LABEL_POOL: IdPool = { next: 20400, end: 20799, free: [] };
const QUEUED_TASK_POOL: IdPool = { next: 20800, end: 21199, free: [] };
const FORMATION_POOL: IdPool = { next: 30000, end: 31999, free: [] };
const FRONT_LINE_POOL: IdPool = { next: 40000, end: 40399, free: [] };
const FRONT_LABEL_POOL: IdPool = { next: 40400, end: 40799, free: [] };
const INSTALLATION_POOL: IdPool = { next: 50000, end: 51999, free: [] };
const BASE_POOL: IdPool = { next: 60000, end: 61999, free: [] };
const OBJECTIVE_POOL: IdPool = { next: 62000, end: 62399, free: [] };

const taskArrows: Record<string, TaskArrow> = {};
const renderedBases: Record<string, TextMark> = {};
const renderedInstallations: Record<string, TextMark> = {};
const renderedObjectives: Record<string, TextMark> = {};
const renderedQueuedTasks: Record<string, TextMark> = {};
const renderedFormations: Record<string, TextMark> = {};
const renderedFrontLines: Record<string, LineMark> = {};
const renderedFrontLabels: Record<string, TextMark> = {};
const reportedFailures: Record<string, boolean> = {};
let logFn: (message: string) => void = () => undefined;
let cleaned = false;

const markPos = (p: WorldPoint): Vec3 => ({ x: p.x, y: 0, z: p.z });
const samePoint = (a: WorldPoint, b: WorldPoint): boolean =>
	a.x === b.x && a.z === b.z;
const sideName = (side: Side): string => cs.SIDE_NAME[side] ?? "?";

function reportFailure(operation: string, error: unknown): void {
	if (reportedFailures[operation]) return;
	reportedFailures[operation] = true;
	const message = `map_overlay ${operation} failed: ${tostring(error)}`;
	logFn(message);
	cs.dbg("mapov", "%s", message);
}
function allocate(pool: IdPool, label: string): number | undefined {
	const recycled = pool.free.pop();
	if (recycled !== undefined) return recycled;
	if (pool.next > pool.end) {
		reportFailure(`${label} id pool exhausted`, pool.end);
		return undefined;
	}
	return pool.next++;
}
function release(pool: IdPool, id: number): void {
	pool.free.push(id);
}
function removeMark(id: number): void {
	const [ok, error] = pcall(trigger.action.removeMark, id);
	if (!ok) reportFailure("removeMark", error);
}
function drawText(id: number, d: DesiredText): boolean {
	const [ok, error] = pcall(
		trigger.action.markToCoalition,
		id,
		d.text,
		markPos(d.pos),
		d.side,
		true,
		"",
	);
	if (!ok) reportFailure("markToCoalition", error);
	return ok;
}
function drawLine(id: number, d: DesiredLine): boolean {
	const [ok, error] = pcall(
		trigger.action.lineToAll,
		d.side,
		id,
		markPos(d.from),
		markPos(d.to),
		d.color,
		MARKUP_LINE_SOLID,
		true,
		"",
	);
	if (!ok) reportFailure("lineToAll", error);
	return ok;
}
function reconcileText(
	desired: Record<string, DesiredText>,
	rendered: Record<string, TextMark>,
	pool: IdPool,
	label: string,
): void {
	for (const [key, prior] of Object.entries(rendered))
		if (desired[key] === undefined) {
			removeMark(prior.id);
			release(pool, prior.id);
			delete rendered[key];
		}
	for (const [key, value] of Object.entries(desired)) {
		const prior = rendered[key];
		if (
			prior &&
			prior.text === value.text &&
			prior.side === value.side &&
			samePoint(prior.pos, value.pos)
		)
			continue;
		const id = prior !== undefined ? prior.id : allocate(pool, label);
		if (prior !== undefined) {
			removeMark(prior.id);
			delete rendered[key];
		}
		if (id === undefined) continue;
		if (drawText(id, value)) rendered[key] = { id, ...value };
		else release(pool, id);
	}
}
function reconcileLines(
	desired: Record<string, DesiredLine>,
	rendered: Record<string, LineMark>,
	pool: IdPool,
	label: string,
): void {
	for (const [key, prior] of Object.entries(rendered))
		if (desired[key] === undefined) {
			removeMark(prior.id);
			release(pool, prior.id);
			delete rendered[key];
		}
	for (const [key, value] of Object.entries(desired)) {
		const prior = rendered[key];
		if (
			prior &&
			prior.side === value.side &&
			samePoint(prior.from, value.from) &&
			samePoint(prior.to, value.to)
		)
			continue;
		const id = prior !== undefined ? prior.id : allocate(pool, label);
		if (prior !== undefined) {
			removeMark(prior.id);
			delete rendered[key];
		}
		if (id === undefined) continue;
		if (drawLine(id, value)) rendered[key] = { id, ...value };
		else release(pool, id);
	}
}

function healthBar(health: number): string {
	const filled = Math.max(
		0,
		Math.min(
			HEALTH_BAR_SEGMENTS,
			Math.floor(health * HEALTH_BAR_SEGMENTS + 0.5),
		),
	);
	return "|".repeat(filled) + ".".repeat(HEALTH_BAR_SEGMENTS - filled);
}
function isObjective(name: string, side: Side): boolean {
	return (S.objectives[side] ?? []).includes(name);
}
function hasDetailedIntel(name: string, viewer: Side): boolean {
	return (
		S.base_owner[name] === viewer || fow.get(name, viewer) >= fow.THRESHOLD_TASK
	);
}
function baseLabel(name: string, owner: Side, viewer: Side): string {
	const objective = isObjective(name, viewer) ? "[OBJECTIVE] " : "";
	if (!hasDetailedIntel(name, viewer))
		return string.format(
			"%s%s [%s]\nINTEL LOW - status unknown",
			objective,
			name,
			sideName(owner),
		);
	const health = S.base_health[name] ?? 1;
	const kind = (S.base_kind[name] ?? "airbase").toUpperCase();
	const pool = S.base_ledger[name];
	let logistics = "logistics unknown";
	if (owner === viewer && pool)
		logistics = string.format(
			"idle F%d E%d H%d R%d T%d | ammo %.0f fuel %.0f | airborne %d",
			pool.striker,
			pool.escort,
			pool.heli,
			pool.recon,
			pool.transport,
			S.base_ammo[name] ?? 0,
			S.base_fuel[name] ?? 0,
			S.base_inflight[name] ?? 0,
		);
	return string.format(
		"%s%s [%s]\n%s%s\n%s %.0f%%\n%s",
		objective,
		name,
		sideName(owner),
		kind,
		S.base_kind[name] === "farp" && !cs.base_is_active(name)
			? " - DORMANT"
			: "",
		healthBar(health),
		health * PERCENT_SCALE,
		logistics,
	);
}
function updateBases(): void {
	const desired: Record<string, DesiredText> = {};
	for (const viewer of SIDES)
		for (const [name, owner] of Object.entries(S.base_owner)) {
			const pos = S.base_pos[name];
			if (!pos) continue;
			// Objectives are known tasking locations. Other enemy bases remain absent until
			// reconnaissance reaches the same threshold used by campaign task generation.
			if (
				owner !== viewer &&
				!isObjective(name, viewer) &&
				!hasDetailedIntel(name, viewer)
			)
				continue;
			desired[`${viewer}:${name}`] = {
				text: baseLabel(name, owner, viewer),
				pos,
				side: viewer,
			};
		}
	reconcileText(desired, renderedBases, BASE_POOL, "base");
}
function nearestBase(pos: WorldPoint): string | undefined {
	let best: string | undefined,
		distance = math.huge;
	for (const [name, base] of Object.entries(S.base_pos)) {
		const d = cs.dist2d(pos.x, pos.z, base.x, base.z);
		if (d < distance) {
			distance = d;
			best = name;
		}
	}
	return best;
}
function updateInstallations(): void {
	const desired: Record<string, DesiredText> = {};
	for (const [name, rec] of Object.entries(S.keysites)) {
		const owner =
			rec.side ?? (rec.home_base ? S.base_owner[rec.home_base] : undefined);
		const intelBase = rec.home_base ?? nearestBase(rec.pos);
		for (const viewer of SIDES) {
			if (
				owner !== undefined &&
				owner !== viewer &&
				(intelBase === undefined || !hasDetailedIntel(intelBase, viewer))
			)
				continue;
			let status = string.format("%.0f%%", (rec.health ?? 1) * PERCENT_SCALE);
			if (rec.pending) status = "EMPTY - place statics";
			else if (rec.total !== undefined)
				status += string.format(" (%d/%d assets)", rec.alive ?? 0, rec.total);
			desired[`${viewer}:${name}`] = {
				text: string.format(
					"%s%s [%s]\n%s",
					rec.low_targets ? "LOW TARGETS " : "",
					rec.label ?? rec.kind,
					owner === undefined ? "CONTESTED" : sideName(owner),
					status,
				),
				pos: rec.pos,
				side: viewer,
			};
		}
	}
	reconcileText(
		desired,
		renderedInstallations,
		INSTALLATION_POOL,
		"installation",
	);
}
function updateObjectives(): void {
	const desired: Record<string, DesiredText> = {};
	for (const side of SIDES) {
		const objectives = S.objectives[side] ?? [];
		for (let i = 0; i < objectives.length; i++) {
			const name = objectives[i],
				pos = S.base_pos[name];
			if (!pos) continue;
			desired[`${side}:${name}`] = {
				text: string.format(
					"OBJECTIVE %d: %s\nINTEL %s",
					i + 1,
					name,
					hasDetailedIntel(name, side) ? "CURRENT" : "LIMITED",
				),
				pos: { x: pos.x, z: pos.z + OBJECTIVE_LABEL_OFFSET_METRES },
				side,
			};
		}
	}
	reconcileText(desired, renderedObjectives, OBJECTIVE_POOL, "objective");
}
function taskTargetPosition(task: BoardTask): WorldPoint | undefined {
	return (
		task.target.pos ??
		(task.target.base ? S.base_pos[task.target.base] : undefined)
	);
}
function updateQueuedTasks(): void {
	const desired: Record<string, DesiredText> = {},
		now = timer.getTime();
	for (const task of S.board_tasks) {
		if (task.state !== "UNASSIGNED") continue;
		const pos = taskTargetPosition(task);
		if (!pos) continue;
		desired[`${task.side}:${task.id}`] = {
			text: string.format(
				"QUEUED %s | priority %d%s\n%s | waiting %.0f min",
				task.type.toUpperCase(),
				task.priority,
				task.critical ? " CRITICAL" : "",
				task.target.base ?? "field target",
				(now - task.created_t) / 60,
			),
			pos,
			side: task.side,
		};
	}
	reconcileText(desired, renderedQueuedTasks, QUEUED_TASK_POOL, "queued task");
}
function leadPosition(group: Group): WorldPoint | undefined {
	const unit = group.getUnit(1);
	if (!unit?.isExist()) return undefined;
	const p = unit.getPosition().p;
	return { x: p.x, z: p.z };
}
function visibleEnemyFormation(pos: WorldPoint, viewer: Side): boolean {
	const base = nearestBase(pos);
	return base !== undefined && fow.get(base, viewer) >= fow.THRESHOLD_TASK;
}
function formationStrength(group: Group): string {
	const current = group.getSize(),
		initial = group.getInitialSize?.();
	return initial !== undefined && initial > 0
		? string.format("%d/%d", current, initial)
		: tostring(current);
}
function addFormation(
	desired: Record<string, DesiredText>,
	key: string,
	group: Group,
	owner: Side,
	kind: string,
	detail: string,
): void {
	if (!cs.group_is_alive(group)) return;
	const pos = leadPosition(group);
	if (!pos) return;
	for (const viewer of SIDES) {
		const friendly = viewer === owner;
		if (!friendly && !visibleEnemyFormation(pos, viewer)) continue;
		desired[`${viewer}:${key}`] = {
			text: friendly
				? string.format(
						"%s %s | strength %s\n%s",
						sideName(owner),
						kind,
						formationStrength(group),
						detail,
					)
				: string.format(
						"ENEMY %s CONTACT\nstrength %s",
						kind,
						formationStrength(group),
					),
			pos,
			side: viewer,
		};
	}
}
function updateFormations(): void {
	const desired: Record<string, DesiredText> = {};
	for (const side of SIDES) {
		for (const [name, rec] of Object.entries(S.ground_groups[side] ?? {}))
			addFormation(
				desired,
				`primary:${name}`,
				rec.grp,
				side,
				"GROUND COLUMN",
				`advancing to ${rec.target_base ?? "awaiting orders"}`,
			);
		for (const [name, rec] of Object.entries(S.arty_groups[side] ?? {}))
			addFormation(
				desired,
				`artillery:${name}`,
				rec.grp,
				side,
				"ARTILLERY",
				rec.moving_to
					? `deploying toward ${rec.moving_to}`
					: `supporting ${rec.home_base}`,
			);
		for (const [name, rec] of Object.entries(S.sec_groups[side] ?? {}))
			addFormation(
				desired,
				`secondary:${name}`,
				rec.grp,
				side,
				"RESERVE",
				rec.behind_base
					? `supporting ${rec.behind_base}`
					: `held at ${rec.home_base}`,
			);
	}
	reconcileText(desired, renderedFormations, FORMATION_POOL, "formation");
}

// Same Gabriel adjacency as frontline.ts. Opposing adjacent pairs become perpendicular FLOT
// segments, instead of the old single closest-pair midpoint.
function adjacent(aName: string, bName: string): boolean {
	const a = S.base_pos[aName],
		b = S.base_pos[bName];
	if (!a || !b) return false;
	const dx = a.x - b.x,
		dz = a.z - b.z,
		d2 = dx * dx + dz * dz;
	if (d2 <= 0) return false;
	for (const [name, p] of Object.entries(S.base_pos)) {
		if (name === aName || name === bName || S.base_owner[name] === undefined)
			continue;
		const ax = a.x - p.x,
			az = a.z - p.z,
			bx = b.x - p.x,
			bz = b.z - p.z;
		if (ax * ax + az * az + bx * bx + bz * bz < d2) return false;
	}
	return true;
}
function updateFront(): void {
	const lines: Record<string, DesiredLine> = {},
		labels: Record<string, DesiredText> = {};
	const names = Object.keys(S.base_owner);
	let segment = 0;
	for (let left = 0; left < names.length; left++)
		for (let right = left + 1; right < names.length; right++) {
			const an = names[left],
				bn = names[right];
			if (S.base_owner[an] === S.base_owner[bn] || !adjacent(an, bn)) continue;
			const a = S.base_pos[an],
				b = S.base_pos[bn];
			if (!a || !b) continue;
			const dx = b.x - a.x,
				dz = b.z - a.z,
				distance = Math.max(Math.sqrt(dx * dx + dz * dz), 1);
			const half = Math.min(
				distance * FRONT_LENGTH_FACTOR,
				FRONT_MAX_HALF_LENGTH_METRES,
			);
			const mid = { x: (a.x + b.x) * 0.5, z: (a.z + b.z) * 0.5 };
			const px = -dz / distance,
				pz = dx / distance;
			const from = { x: mid.x - px * half, z: mid.z - pz * half },
				to = { x: mid.x + px * half, z: mid.z + pz * half };
			for (const viewer of SIDES) {
				const enemyBase = S.base_owner[an] === viewer ? bn : an;
				if (
					!isObjective(enemyBase, viewer) &&
					!hasDetailedIntel(enemyBase, viewer)
				)
					continue;
				const key = `${viewer}:${an}:${bn}`;
				const enemy = cs.ENEMY[viewer];
				let enemyBases = 0;
				let knownEnemyBases = 0;
				for (const [name, owner] of Object.entries(S.base_owner))
					if (owner === enemy) {
						enemyBases += 1;
						if (hasDetailedIntel(name, viewer)) knownEnemyBases += 1;
					}
				const enemyStrength =
					enemyBases > 0 && knownEnemyBases === enemyBases
						? tostring(S.strength[enemy] ?? 0)
						: "UNKNOWN";
				lines[key] = { from, to, side: viewer, color: [1, 0.55, 0.1, 0.85] };
				labels[key] = {
					text:
						segment === 0
							? string.format(
									"FLOT\n%s strength %d | enemy strength %s",
									sideName(viewer),
									S.strength[viewer] ?? 0,
									enemyStrength,
								)
							: "FLOT",
					pos: mid,
					side: viewer,
				};
			}
			segment++;
		}
	reconcileLines(lines, renderedFrontLines, FRONT_LINE_POOL, "front line");
	reconcileText(labels, renderedFrontLabels, FRONT_LABEL_POOL, "front label");
}
function inferTaskLabel(
	groupName: string,
	side: Side,
	target: WorldPoint,
): string {
	const active = S.active_tasks[groupName];
	if (active !== undefined)
		return string.format(
			"ACTIVE %s\n%s",
			active.task_type.toUpperCase(),
			active.target_base ?? "field target",
		);
	for (const task of S.board_tasks) {
		const pos = taskTargetPosition(task);
		if (
			task.side === side &&
			pos &&
			cs.dist2d(pos.x, pos.z, target.x, target.z) < 10
		)
			return string.format(
				"ACTIVE %s\n%s",
				task.type.toUpperCase(),
				task.target.base ?? "field target",
			);
	}
	return "ACTIVE MISSION";
}
export function remove_task_arrow(groupName: string): void {
	const arrow = taskArrows[groupName];
	if (!arrow) return;
	removeMark(arrow.lineId);
	release(TASK_LINE_POOL, arrow.lineId);
	if (arrow.labelId !== undefined) {
		removeMark(arrow.labelId);
		release(TASK_LABEL_POOL, arrow.labelId);
	}
	delete taskArrows[groupName];
}
export function add_task_arrow(
	groupName: string,
	from: WorldPoint,
	to: WorldPoint,
	side: Side,
): number | undefined {
	if (!groupName || !from || !to) return undefined;
	remove_task_arrow(groupName);
	const lineId = allocate(TASK_LINE_POOL, "task line");
	if (lineId === undefined) return undefined;
	if (
		!drawLine(lineId, {
			from,
			to,
			side,
			color: side === BLUE ? [0.2, 0.45, 1, 0.75] : [1, 0.2, 0.2, 0.75],
		})
	) {
		release(TASK_LINE_POOL, lineId);
		return undefined;
	}
	let labelId = allocate(TASK_LABEL_POOL, "task label");
	if (
		labelId !== undefined &&
		!drawText(labelId, {
			text: inferTaskLabel(groupName, side, to),
			pos: { x: (from.x + to.x) * 0.5, z: (from.z + to.z) * 0.5 },
			side,
		})
	) {
		release(TASK_LABEL_POOL, labelId);
		labelId = undefined;
	}
	taskArrows[groupName] = { lineId, labelId };
	return lineId;
}
function gcTasks(): void {
	for (const groupName of Object.keys(taskArrows)) {
		const [ok, group] = pcall(Group.getByName, groupName);
		if (!ok || group?.isExist() !== true) remove_task_arrow(groupName);
	}
}
function currentlyManaged(id: number): boolean {
	for (const arrow of Object.values(taskArrows))
		if (arrow.lineId === id || arrow.labelId === id) return true;
	for (const registry of [
		renderedBases,
		renderedInstallations,
		renderedObjectives,
		renderedQueuedTasks,
		renderedFormations,
		renderedFrontLabels,
	])
		for (const mark of Object.values(registry)) if (mark.id === id) return true;
	for (const line of Object.values(renderedFrontLines))
		if (line.id === id) return true;
	return false;
}
function cleanupLeaks(): void {
	if (cleaned) return;
	cleaned = true;
	const [ok, panels] = pcall(world.getMarkPanels);
	if (!ok) {
		reportFailure("getMarkPanels", panels);
		return;
	}
	for (const panel of panels ?? []) {
		const id = panel.idx ?? -1;
		if (currentlyManaged(id)) continue;
		if (
			(id >= 20000 && id <= 21199) ||
			(id >= 30000 && id <= 31999) ||
			(id >= 40000 && id <= 40799) ||
			(id >= 50000 && id <= 51999) ||
			(id >= 60000 && id <= 62399) ||
			(id >= 70000 && id <= 70400) ||
			(id >= 3000100 && id <= 3000299)
		)
			removeMark(id);
	}
}
function refresh(): void {
	const [ok, error] = pcall(() => {
		cleanupLeaks();
		updateBases();
		updateInstallations();
		updateObjectives();
		updateQueuedTasks();
		updateFormations();
		updateFront();
		gcTasks();
	});
	if (!ok) reportFailure("refresh", error);
}
export function schedule_overlay(
	logger: (message: string) => void = () => undefined,
): void {
	logFn = logger;
	const generation = cs.GENERATION;
	cs.set_task_end_hook(remove_task_arrow);
	cs.dbg(
		"mapov",
		"coalition operational overlay REGISTERED offset=%.0fs period=%.0fs",
		OVERLAY_INITIAL_DELAY_SECONDS,
		UPDATE_PERIOD_SECONDS,
	);
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			refresh();
			return time + UPDATE_PERIOD_SECONDS;
		},
		undefined,
		timer.getTime() + OVERLAY_INITIAL_DELAY_SECONDS,
	);
}
