/** @noSelfInFile */
/*
-- recon.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c  create_recon_task (called from the
--   strike-vs-recon fork in create_bai_tasks:785, create_sead_tasks:2093, create_oca_*_tasks,
--   create_keysite_strike_tasks:1051) and aphavoc/source/ai/highlevl/reaction.c (recon of AA
--   groups / frontline groups → SEAD/BAI chain).
--
-- THE RECON FORK (the single most important behavioural fix): in EECH the fog-of-war gate on a
-- strike task is not a filter that drops fogged targets — it is a FORK. When the highest-value
-- candidate's sector is under-reconned, the task generator creates a RECON task INSTEAD of the
-- strike. The recon flight overflies the target, which raises that sector's fog-of-war value, so
-- next cycle the target is revealed and becomes strikeable. Without this, a fogged sector never
-- generates recon → its FOW never rises → the target is invisible to the tasker forever (a dead
-- loop). EECH self-heals; the previous port self-stalled.
--
-- A recon flight is a fast, high-altitude overflight of the target. Its presence near the target
-- keysite grants fog-of-war to the recon side via fog_of_war.lua's per-unit recon scan. It draws
-- from the side's "recon" reserve pool, RTBs, and is recycled on landing (supply.make_land_handler).
*/
import * as board from "./task_board";
import * as config from "./config";
import * as croute from "./croute";
import * as cs from "./campaign_state";
import * as ov from "./map_overlay";
import type { WorldPoint } from "./campaign_types";

import type { Side } from "./campaign_types";
type LogFunction = (this: void, message: string) => void;

export interface ReconObjective {
	kind: string;
	base?: string;
	group?: Group;
	pos?: WorldPoint;
}

interface ReconAircraft {
	country: number;
	recon: string;
}

const AC: Record<number, ReconAircraft> = {};
for (const side of [coalition.side.BLUE, coalition.side.RED]) {
	AC[side] = {
		country: config.C.countries[side],
		recon: config.C.types.aircraft[side].recon,
	};
}

const RECON_ALT = 8000; // m AMSL — high overflight
const RECON_SPEED = 300; // m/s ≈ 580 kt — fast dash in/out

// Builder contract: the task board has already consumed one recon aircraft from baseName.
// It refunds the inventory when this returns undefined.
function buildRecon(
	side: Side,
	baseName: string,
	targetPos: WorldPoint,
	label: string,
	logFn: LogFunction,
	objective?: ReconObjective,
): Group | undefined {
	const homeAirbase = Airbase.getByName(baseName);
	if (homeAirbase === undefined) {
		cs.dbg(
			"recon",
			"%s build_recon ABORT: base %s not found",
			cs.SIDE_NAME[side],
			tostring(baseName),
		);
		return undefined;
	}

	const cfg = AC[side];
	const airbasePos = homeAirbase.getPosition().p;
	const [baseX, baseY] = cs.wp_xy(airbasePos);
	const [targetX, targetY] = cs.wp_xy(targetPos);
	const id = cs.next_id();
	const groupName = string.format("Recon-%d-%d", side, id);
	const group = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
		name: groupName,
		task: "Reconnaissance",
		hidden: false,
		airdromeId: homeAirbase.getID(),
		units: [
			{
				name: `${groupName}-1`,
				type: cfg.recon,
				skill: "High",
				x: airbasePos.x,
				y: airbasePos.z,
				alt: airbasePos.y,
				alt_type: "BARO",
				speed: 0,
				heading: cs.heading_to(
					airbasePos.x,
					airbasePos.z,
					targetPos.x,
					targetPos.z,
				),
				payload: { fuel: 5200, flare: 120, chaff: 120, gun: 100 },
			},
		],
		route: {
			points: croute.expand(
				[
					{
						type: "TakeOffParkingHot",
						action: "From Parking Area Hot",
						airdromeId: homeAirbase.getID(),
						alt: airbasePos.y,
						alt_type: "BARO",
						speed: 0,
						ETA: 0,
						ETA_locked: true,
						x: baseX,
						y: baseY,
						name: "Depart",
						formation_template: "",
					},
					{
						type: "Turning Point",
						action: "Fly Over Point",
						alt: RECON_ALT,
						alt_type: "BARO",
						speed: RECON_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: targetX,
						y: targetY,
						name: "Recon",
						formation_template: "",
					},
					{
						type: "Land",
						action: "Landing",
						airdromeId: homeAirbase.getID(),
						alt: airbasePos.y,
						alt_type: "BARO",
						speed: RECON_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: baseX,
						y: baseY,
						name: "RTB",
						formation_template: "",
					},
				],
				side,
				{ alt: RECON_ALT, alt_type: "BARO", speed: RECON_SPEED, name: "Nav" },
			),
		},
	});

	if (group !== undefined) {
		cs.register_task(groupName, {
			task_type: "recon",
			side,
			target_base: objective?.base,
			target_pos: targetPos,
			objective: objective ?? { kind: "keysite" },
			born_time: timer.getTime(),
		});
		ov.add_task_arrow(groupName, airbasePos, targetPos, side);
		logFn(
			string.format(
				"%s %s RECON #%d from %s → (%.0f,%.0f)",
				cs.SIDE_NAME[side],
				label,
				id,
				homeAirbase.getName(),
				targetPos.x,
				targetPos.z,
			),
		);
		cs.dbg(
			"recon",
			"%s RECON #%d spawned from %s -> obj=%s",
			cs.SIDE_NAME[side],
			id,
			homeAirbase.getName(),
			objective !== undefined ? (objective.base ?? objective.kind) : "pos",
		);
		return group;
	}
	cs.dbg(
		"recon",
		"%s RECON spawn FAILED from %s (addGroup returned nil)",
		cs.SIDE_NAME[side],
		baseName,
	);
	return undefined;
}

// SINGLE-SHOT EXPORT. Creates a task and asks the board to assign it immediately. If no reachable
// inventory exists, the task remains unassigned until its ten-minute expiry.
export function spawn_recon(
	side: Side,
	targetPos: WorldPoint | undefined,
	label = "RECON",
	logFn: LogFunction = () => undefined,
	objective?: ReconObjective,
	critical?: boolean,
): boolean {
	if (targetPos === undefined) {
		cs.dbg(
			"recon",
			"%s spawn_recon ABORT: no target_pos (label=%s)",
			cs.SIDE_NAME[side],
			label,
		);
		return false;
	}
	cs.dbg(
		"recon",
		"%s spawn_recon: queueing task (label=%s obj=%s)",
		cs.SIDE_NAME[side],
		label,
		objective !== undefined ? (objective.base ?? objective.kind) : "pos",
	);
	board.create_task({
		type: "recon",
		side,
		count: 1,
		immediate: true,
		log_fn: logFn,
		critical,
		target: {
			base: objective?.base,
			pos: targetPos,
			group: objective?.group,
			objective,
		},
		builder: (baseName: string) =>
			buildRecon(side, baseName, targetPos, label, logFn, objective),
	});
	return true;
}
