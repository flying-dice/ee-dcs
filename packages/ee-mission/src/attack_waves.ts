/** @noSelfInFile */
/*
-- attack_waves.lua
-- Inspired by:
--   aphavoc/source/ai/highlevl/highlevl.c   create_oca_strike_tasks (every 30 min campaign),
--                                            create_keysite_strike_tasks (every 7.5 min),
--                                            create_bai_tasks (every 20 min),
--                                            add_high_level_ai_function + staggered offset
--   aphavoc/source/ai/highlevl/reaction.c   escort created reactively when task difficulty
--                                            >= escort_required_threshold
--   aphavoc/source/ai/taskgen/taskgen.h     create_escort_task factory function
--   aphavoc/source/ai/highlevl/suitable.c   suitability matrix: ARMED_FW for strike,
--                                            FIGHTER for escort (category-based selection)
--
-- Generates periodic fixed-wing strike packages against enemy airbases and installations.
-- Each package is a fixed-size strike flight (STRIKE_PACKAGE_SIZE = 2); the escort count is
-- threat-thresholded per the reaction.c escort_required gate (assign.c:598-627), NOT scaled by
-- campaign phase (the old phase-scaling wave table was removed). Strike cadence is mode-selected
-- (campaign vs skirmish) via campaign_mode.lua.
*/
import * as cs from "./campaign_state";
import * as keysite from "./keysite";
import * as croute from "./croute";
import * as supply from "./supply";
import * as ov from "./map_overlay";
import * as config from "./config";
import * as board from "./task_board";
import * as recon from "./recon";
import * as fow from "./fog_of_war";
import * as mode from "./campaign_mode";

const S = cs.S;
import type { Side } from "./campaign_types";
type LogFn = (message: string) => void;
type Intent = "oca" | "ground";
const noop: LogFn = () => undefined;

interface AircraftConfig {
	country: number;
	striker: string;
	escort: string;
}
interface InstallationModule {
	damage(this: void, name: string, amount: number, logFn: LogFn): void;
}

const FOW_OCA_THRESHOLD = 0.25; // highlevl.c:1433
const PYLON = config.C.payloads;
const AC: Record<number, AircraftConfig> = {};
for (const side of [coalition.side.BLUE, coalition.side.RED]) {
	AC[side] = {
		country: config.C.countries[side],
		striker: config.C.types.aircraft[side].striker,
		escort: config.C.types.aircraft[side].escort,
	};
}

const STRIKE_PACKAGE_SIZE = 2;
const STRIKE_ALT = 6000;
const ESCORT_ALT = 7000;
const STRIKE_SPEED = 220;
const INSTALLATION_STRIKE_DMG = 0.5;
const INSTALLATION_TIME_ON_TARGET = 150;
const KEYSITE_STRIKE_DMG = 0.28;
const OCA_STRIKE_DMG = 0.16;
const KEYSITE_TIME_ON_TARGET = 240;

function targetPosition(
	name: string,
): import("./campaign_types").WorldPoint | undefined {
	return S.base_pos[name] ?? S.keysites[name]?.pos;
}

function strikeWaypoints(
	home: Airbase,
	abPos: Vec3,
	targetPos: import("./campaign_types").WorldPoint,
): WaypointData[] {
	const [bx, by] = cs.wp_xy(abPos);
	const tx = targetPos.x;
	const ty = targetPos.z;
	return [
		{
			type: "TakeOffParkingHot",
			action: "From Parking Area Hot",
			airdromeId: home.getID(),
			alt: abPos.y,
			alt_type: "BARO",
			speed: 0,
			ETA: 0,
			ETA_locked: true,
			x: bx,
			y: by,
			name: "Depart",
			formation_template: "",
		},
		{
			type: "Turning Point",
			action: "Turning Point",
			alt: STRIKE_ALT,
			alt_type: "BARO",
			speed: STRIKE_SPEED,
			ETA: 0,
			ETA_locked: false,
			x: tx,
			y: ty,
			name: "Strike",
			formation_template: "",
			task: {
				id: "ComboTask",
				params: {
					tasks: [
						{
							number: 1,
							auto: true,
							id: "EngageTargets",
							enabled: true,
							params: {
								maxDist: 10000,
								priority: 0,
								targetTypes: ["Ground Units", "Helicopters"],
							},
						},
					],
				},
			},
		},
		{
			type: "Land",
			action: "Landing",
			airdromeId: home.getID(),
			alt: abPos.y,
			alt_type: "BARO",
			speed: STRIKE_SPEED,
			ETA: 0,
			ETA_locked: false,
			x: bx,
			y: by,
			name: "RTB",
			formation_template: "",
		},
	];
}

function escortWaypoints(
	home: Airbase,
	abPos: Vec3,
	targetPos: import("./campaign_types").WorldPoint,
): WaypointData[] {
	const [bx, by] = cs.wp_xy(abPos);
	const tx = targetPos.x;
	const ty = targetPos.z;
	return [
		{
			type: "TakeOffParkingHot",
			action: "From Parking Area Hot",
			airdromeId: home.getID(),
			alt: abPos.y,
			alt_type: "BARO",
			speed: 0,
			ETA: 0,
			ETA_locked: true,
			x: bx,
			y: by,
			name: "Depart",
			formation_template: "",
		},
		{
			type: "Turning Point",
			action: "Turning Point",
			alt: ESCORT_ALT,
			alt_type: "BARO",
			speed: STRIKE_SPEED,
			ETA: 0,
			ETA_locked: false,
			x: tx,
			y: ty,
			name: "Sweep",
			formation_template: "",
			task: {
				id: "ComboTask",
				params: {
					tasks: [
						{
							number: 1,
							auto: true,
							id: "EngageTargets",
							enabled: true,
							params: { maxDist: 40000, priority: 0, targetTypes: ["Air"] },
						},
					],
				},
			},
		},
		{
			type: "Land",
			action: "Landing",
			airdromeId: home.getID(),
			alt: abPos.y,
			alt_type: "BARO",
			speed: STRIKE_SPEED,
			ETA: 0,
			ETA_locked: false,
			x: bx,
			y: by,
			name: "RTB",
			formation_template: "",
		},
	];
}

function buildStrikePackage(
	side: Side,
	baseName: string,
	targetName: string,
	logFn: LogFn,
	intent: Intent,
): Group | undefined {
	const cfg = AC[side];
	const installation = S.base_pos[targetName] === undefined;
	const targetPos = targetPosition(targetName);
	if (targetPos === undefined) {
		logFn(`strike: no position for ${targetName}`);
		cs.dbg(
			"strike",
			"%s build_strike_package ABORT: no position for target %s",
			cs.SIDE_NAME[side],
			targetName,
		);
		return undefined;
	}
	const home = Airbase.getByName(baseName);
	if (home === undefined) {
		cs.dbg(
			"strike",
			"%s build_strike_package ABORT: base %s not found",
			cs.SIDE_NAME[side],
			baseName,
		);
		return undefined;
	}
	const abPos = home.getPosition().p;
	const heading = cs.heading_to(abPos.x, abPos.z, targetPos.x, targetPos.z);
	const sid = cs.next_id();
	const prefix = intent === "oca" ? "OCAStrike" : "KStrike";
	const name = string.format("%s-%d", prefix, sid);
	const taskType = intent === "oca" ? "oca_strike" : "ground_strike";
	const escorts = cs.escort_count(taskType, side, abPos, targetPos, logFn);
	const units: UnitData[] = [];
	for (let i = 1; i <= STRIKE_PACKAGE_SIZE; i += 1) {
		units.push({
			name: `${name}-${i}`,
			type: cfg.striker,
			skill: "Good",
			x: abPos.x + (i - 1) * 20,
			y: abPos.z,
			alt: abPos.y,
			alt_type: "BARO",
			speed: 0,
			heading,
			payload: {
				fuel: 4900,
				flare: 60,
				chaff: 60,
				gun: 100,
				pylons: PYLON[side].striker,
			},
		});
	}
	const strike = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
		name,
		task: "Ground Attack",
		hidden: false,
		airdromeId: home.getID(),
		units,
		route: {
			points: croute.expand(strikeWaypoints(home, abPos, targetPos), side, {
				alt: STRIKE_ALT,
				alt_type: "BARO",
				speed: STRIKE_SPEED,
				name: "Nav",
			}),
		},
	});
	if (strike === undefined) {
		logFn(
			string.format(
				"Strike %d FAILED: %s → %s",
				sid,
				cs.SIDE_NAME[side],
				targetName,
			),
		);
		cs.dbg(
			"strike",
			"%s Strike #%d (%s) SPAWN FAILED -> %s",
			cs.SIDE_NAME[side],
			sid,
			intent,
			targetName,
		);
		return undefined;
	}
	cs.register_task(name, {
		task_type: taskType,
		side,
		target_base: targetName,
		target_pos: targetPos,
		objective: { kind: "keysite", base: targetName },
		born_time: timer.getTime(),
		eff_before:
			S.base_health[targetName] ?? S.keysites[targetName]?.health ?? 1,
	});
	const generation = _DMT_GEN;
	if (!installation) {
		const damage = intent === "oca" ? OCA_STRIKE_DMG : KEYSITE_STRIKE_DMG;
		timer.scheduleFunction(
			() => {
				if (_DMT_GEN === generation)
					keysite.strike_damage(targetName, damage, logFn);
				return undefined;
			},
			undefined,
			timer.getTime() + KEYSITE_TIME_ON_TARGET,
		);
	} else {
		timer.scheduleFunction(
			() => {
				if (_DMT_GEN === generation)
					require<InstallationModule>("installations").damage(
						targetName,
						INSTALLATION_STRIKE_DMG,
						logFn,
					);
				return undefined;
			},
			undefined,
			timer.getTime() + INSTALLATION_TIME_ON_TARGET,
		);
	}
	logFn(
		string.format(
			"Strike %d: %s %dx%s from %s → %s (escorts=%d)",
			sid,
			cs.SIDE_NAME[side],
			STRIKE_PACKAGE_SIZE,
			cfg.striker,
			home.getName(),
			targetName,
			escorts,
		),
	);
	ov.add_task_arrow(name, abPos, targetPos, side);
	cs.dbg(
		"strike",
		"%s Strike #%d (%s) spawned from %s -> %s (installation=%s, dmg scheduled +%.0fs)",
		cs.SIDE_NAME[side],
		sid,
		intent,
		home.getName(),
		targetName,
		tostring(installation),
		installation ? INSTALLATION_TIME_ON_TARGET : KEYSITE_TIME_ON_TARGET,
	);

	if (escorts > 0 && supply.consume_base(baseName, "escort", escorts)) {
		const eid = cs.next_id();
		const escortName = string.format("Escort-%d", eid);
		const escortUnits: UnitData[] = [];
		for (let i = 1; i <= escorts; i += 1) {
			escortUnits.push({
				name: `${escortName}-${i}`,
				type: cfg.escort,
				skill: "High",
				x: abPos.x + (i - 1) * 20,
				y: abPos.z,
				alt: abPos.y,
				alt_type: "BARO",
				speed: 0,
				heading,
				payload: {
					fuel: 5200,
					flare: 120,
					chaff: 120,
					gun: 100,
					pylons: PYLON[side].escort,
				},
			});
		}
		const [ok, escort] = pcall(() =>
			coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
				name: escortName,
				task: "Fighter Sweep",
				hidden: false,
				airdromeId: home.getID(),
				units: escortUnits,
				route: {
					points: croute.expand(escortWaypoints(home, abPos, targetPos), side, {
						alt: ESCORT_ALT,
						alt_type: "BARO",
						speed: STRIKE_SPEED,
						name: "Nav",
					}),
				},
			}),
		);
		if (ok && escort !== undefined) {
			logFn(
				string.format(
					"Escort %d: %s %dx%s from %s for Strike-%d",
					eid,
					cs.SIDE_NAME[side],
					escorts,
					cfg.escort,
					home.getName(),
					sid,
				),
			);
			cs.dbg(
				"strike",
				"%s Escort #%d spawned for Strike-%d",
				cs.SIDE_NAME[side],
				eid,
				sid,
			);
		} else {
			supply.recycle_base(baseName, "escort", escorts);
			cs.dbg(
				"strike",
				"%s Escort for Strike-%d FAILED (pcall_ok=%s) -> refunded",
				cs.SIDE_NAME[side],
				sid,
				tostring(ok),
			);
		}
	}
	return strike;
}

function createStrikeTask(
	side: Side,
	targetName: string,
	logFn: LogFn,
	intent: Intent,
	immediate = false,
	critical?: boolean,
): boolean {
	const pos = targetPosition(targetName);
	if (pos === undefined) {
		logFn(`strike: no position for ${targetName}`);
		return false;
	}
	const type = intent === "oca" ? "oca_strike" : "ground_strike";
	cs.dbg(
		"strike",
		"%s create_strike_task: %s vs %s (strikers=%d, immediate=%s)",
		cs.SIDE_NAME[side],
		type,
		targetName,
		STRIKE_PACKAGE_SIZE,
		tostring(immediate),
	);
	board.create_task({
		type,
		side,
		count: STRIKE_PACKAGE_SIZE,
		log_fn: logFn,
		immediate,
		critical,
		target: { base: targetName, pos },
		builder: (baseName: string) =>
			buildStrikePackage(side, baseName, targetName, logFn, intent),
	});
	return true;
}

const KEYSITE_STRIKE_PERIOD = mode.SCHED.keysite_strike.period;
const OCA_STRIKE_PERIOD = mode.SCHED.oca_strike.period;

function runScheduledStrike(side: Side, intent: Intent, logFn: LogFn): void {
	if (intent === "ground") {
		const decisions = keysite.pick_targets(side, 3, logFn);
		if (decisions.length === 0) {
			logFn(`${cs.SIDE_NAME[side]}: no valid ground strike target`);
			return;
		}
		for (const decision of decisions) {
			if (decision.action === "recon")
				recon.spawn_recon(
					side,
					{ x: decision.pos.x, y: decision.pos.y ?? 0, z: decision.pos.z },
					"KStrikeRecon",
					logFn,
					{ kind: "keysite", base: decision.name },
				);
			else createStrikeTask(side, decision.name, logFn, "ground");
		}
		return;
	}
	const [target] = keysite.pick_target(side, logFn, keysite.RATE_OCA_STRIKE);
	if (target === undefined) {
		logFn(`${cs.SIDE_NAME[side]}: no valid oca strike target`);
		cs.dbg("strike", "%s OCA strike: no valid target", cs.SIDE_NAME[side]);
		return;
	}
	const visibility = fow.get(target, side) ?? 0;
	if (visibility < FOW_OCA_THRESHOLD) {
		cs.dbg(
			"strike",
			"%s OCA strike SKIPPED: %s fogged (fow=%.2f < %.2f)",
			cs.SIDE_NAME[side],
			target,
			visibility,
			FOW_OCA_THRESHOLD,
		);
	} else if (
		cs.has_task_against("oca_strike", target, side) ||
		cs.has_task_against("bda", target, side) ||
		cs.has_task_against("troop_insertion", target, side)
	) {
		cs.dbg(
			"strike",
			"%s OCA strike SKIPPED: %s already tasked (dedup)",
			cs.SIDE_NAME[side],
			target,
		);
	} else createStrikeTask(side, target, logFn, "oca");
}

function schedule(
	side: Side,
	initialOffset: number,
	logFn: LogFn,
	intent: Intent,
	period: number,
): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"strike",
		"%s %s-strike scheduler REGISTERED offset=%.0fs period=%.0fs",
		cs.SIDE_NAME[side],
		intent === "ground" ? "keysite" : "oca",
		initialOffset,
		period,
	);
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			cs.dbg(
				"strike",
				"%s %s-strike FIRE",
				cs.SIDE_NAME[side],
				intent === "ground" ? "keysite" : "oca",
			);
			runScheduledStrike(side, intent, logFn);
			return time + period;
		},
		undefined,
		timer.getTime() + initialOffset,
	);
}

export function schedule_keysite_strikes(
	side: Side,
	initialOffset: number,
	logFn: LogFn = noop,
): void {
	schedule(side, initialOffset, logFn, "ground", KEYSITE_STRIKE_PERIOD);
}

export function schedule_oca_strikes(
	side: Side,
	initialOffset: number,
	logFn: LogFn = noop,
): void {
	schedule(side, initialOffset, logFn, "oca", OCA_STRIKE_PERIOD);
}

function runSingle(
	side: Side,
	intent: Intent,
	targetOverride?: string,
	logFn: LogFn = noop,
	critical?: boolean,
): void {
	const weights =
		intent === "oca" ? keysite.RATE_OCA_STRIKE : keysite.RATE_GROUND_STRIKE;
	let target = targetOverride;
	if (target === undefined) {
		const [picked] = keysite.pick_target(side, logFn, weights);
		target = picked;
	}
	if (target === undefined) {
		cs.dbg(
			"strike",
			"%s run_single(%s) ABORT: no target resolved",
			cs.SIDE_NAME[side],
			intent,
		);
		return;
	}
	cs.dbg(
		"strike",
		"%s run_single(%s): single-shot vs %s (override=%s)",
		cs.SIDE_NAME[side],
		intent,
		target,
		tostring(targetOverride !== undefined),
	);
	const [ok, error] = pcall(() =>
		createStrikeTask(side, target, logFn, intent, true, critical),
	);
	if (!ok) logFn(`run_${intent}_strike error: ${tostring(error)}`);
}

// Single-shot exports required by the reaction chain.
export function run_strike(
	side: Side,
	logFn: LogFn = noop,
	targetName?: string,
	critical?: boolean,
): void {
	runSingle(side, "ground", targetName, logFn, critical);
}

export function run_oca_strike(
	side: Side,
	logFn: LogFn = noop,
	targetName?: string,
	critical?: boolean,
): void {
	runSingle(side, "oca", targetName, logFn, critical);
}
