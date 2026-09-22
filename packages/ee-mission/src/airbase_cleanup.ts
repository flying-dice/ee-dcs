/** @noSelfInFile */
/* DCS adapter: remove movable AI ground groups obstructing airfield movement surfaces. */
import * as clearance from "./airbase_clearance";
import * as cs from "./campaign_state";
import type { WorldPoint } from "./campaign_types";
import { type AnyCoalition, BLUE, NEUTRAL, RED } from "./sides";

const PERIOD_SECONDS = 30;
const ROUTE_SPEED_METRES_PER_SECOND = 4;
const ROUTE_MARGIN_METRES = 200;
const RETRY_SECONDS = 120;
const PROGRESS_METRES = 50;
type LogFn = (message: string) => void;
let trackedGeneration = -1;
type Attempt = { x: number; z: number; at: number };
let ordered: Record<string, Attempt> = {};
let failed: Record<string, number> = {};

export function sweep(logFn: LogFn = env.info): void {
	if (trackedGeneration !== cs.GENERATION) {
		trackedGeneration = cs.GENERATION;
		ordered = {};
		failed = {};
	}
	let detected = 0;
	let routed = 0;
	let cleared = 0;
	let failures = 0;
	const seen: Record<string, boolean> = {};
	const coalitions: AnyCoalition[] = [NEUTRAL, BLUE, RED];
	for (const side of coalitions) {
		const [readOk, groups] = pcall(() =>
			coalition.getGroups(side, Group.Category.GROUND),
		);
		if (!readOk || !groups) continue;
		for (const group of groups) {
			const [nameOk, name] = pcall(() => group.getName());
			if (!nameOk || !name) continue;
			seen[name] = true;
			const [unitsOk, units] = pcall(() => group.getUnits());
			if (!unitsOk || !units || units.length === 0) continue;
			let blocked = false;
			let inside: WorldPoint | undefined;
			let lead: WorldPoint | undefined;
			let player = false;
			for (const unit of units) {
				const [readUnit, data] = pcall(() => ({
					point: unit.getPoint(),
					player: unit.getPlayerName(),
				}));
				if (!readUnit || !data) {
					blocked = true;
					break;
				}
				if (data.player !== undefined) player = true;
				lead ??= { x: data.point.x, z: data.point.z };
				const [clearOk, clear] = pcall(() =>
					clearance.is_clear(data.point.x, data.point.z),
				);
				if (!clearOk) {
					blocked = true;
					break;
				}
				if (!clear) inside = { x: data.point.x, z: data.point.z };
			}
			if (player || blocked || !lead) continue;
			if (!inside) {
				if (ordered[name]) {
					delete ordered[name];
					cleared++;
					logFn(`[airbase_clearance] cleared ${name}`);
				}
				delete failed[name];
				continue;
			}
			detected++;
			const prior = ordered[name];
			if (
				prior &&
				cs.dist2d(lead.x, lead.z, prior.x, prior.z) >= PROGRESS_METRES
			) {
				prior.x = lead.x;
				prior.z = lead.z;
				prior.at = timer.getTime();
			}
			if (prior && timer.getTime() - prior.at < RETRY_SECONDS) continue;
			if (
				failed[name] !== undefined &&
				timer.getTime() - failed[name] < RETRY_SECONDS
			)
				continue;
			if (prior !== undefined)
				logFn(`[airbase_clearance] stalled ${name}: retrying evacuation`);
			const [targetOk, target] = pcall(() =>
				clearance.find_clear(inside, inside, ROUTE_MARGIN_METRES, name),
			);
			if (!targetOk || !target) {
				failed[name] = timer.getTime();
				failures++;
				logFn(`[airbase_clearance] failed ${name}: no safe route destination`);
				continue;
			}
			const [taskOk] = pcall(() =>
				group.getController().setTask({
					id: "Mission",
					params: {
						route: {
							points: [
								{
									type: "Turning Point",
									action: "Off Road",
									x: lead.x,
									y: lead.z,
									alt: land.getHeight({ x: lead.x, y: lead.z }),
									alt_type: "BARO",
									speed: ROUTE_SPEED_METRES_PER_SECOND,
									ETA: 0,
									ETA_locked: false,
								},
								{
									type: "Turning Point",
									action: "Off Road",
									x: target.x,
									y: target.z,
									alt: land.getHeight({ x: target.x, y: target.z }),
									alt_type: "BARO",
									speed: ROUTE_SPEED_METRES_PER_SECOND,
									ETA: 0,
									ETA_locked: false,
								},
							],
						},
					},
				}),
			);
			if (taskOk) {
				ordered[name] = { x: lead.x, z: lead.z, at: timer.getTime() };
				delete failed[name];
				routed++;
				logFn(
					string.format(
						"[airbase_clearance] routed %s to %.0f,%.0f",
						name,
						target.x,
						target.z,
					),
				);
			} else {
				failed[name] = timer.getTime();
				failures++;
				logFn(`[airbase_clearance] failed ${name}: route task rejected`);
			}
		}
	}
	for (const [name] of pairs(ordered)) if (!seen[name]) delete ordered[name];
	for (const [name] of pairs(failed)) if (!seen[name]) delete failed[name];
	if (routed > 0 || cleared > 0 || failures > 0)
		logFn(
			string.format(
				"[airbase_clearance] sweep detected=%d routed=%d cleared=%d failed=%d",
				detected,
				routed,
				cleared,
				failures,
			),
		);
}

export function schedule(logFn: LogFn = env.info): void {
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		(_, t) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok] = pcall(() => sweep(logFn));
			if (!ok)
				logFn("[airbase_clearance] sweep failed; retrying next interval");
			return t + PERIOD_SECONDS;
		},
		undefined,
		timer.getTime() + PERIOD_SECONDS,
	);
}
