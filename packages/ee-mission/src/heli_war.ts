/** @noSelfInFile */
/*
-- heli_war.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c (create_cas_tasks / anti-armour tasks),
--   aphavoc/source/ai/highlevl/suitable.c (suitability matrix — ATTACK_HELICOPTER is the primary
--   suitable type for anti-armour / CAS / armed-recon / escort in campaign),
--   aphavoc/source/entity/helicopter/* (attack helicopter behaviour).
--
-- EECH ("Enemy Engaged": Comanche vs Hokum / Apache vs Havoc) is FUNDAMENTALLY a helicopter combat
-- sim — attack helicopters are the main offensive arm and the bulk of the campaign's sorties. The
-- fixed-wing strike/CAS/BAI/SEAD tasks (attack_waves / cas_bai_sead) model the air-force layer; THIS
-- module models the rotary-wing war that is the heart of the game:
--   1. Anti-armour sorties  — attack-heli sections hunt enemy frontline ground groups (core mission)
--   2. Hunter-killer recon  — armed recon along the front, engaging ground AND air (incl. enemy helis)
--   3. Attack-heli escort   — escorts transport/BDA/troop-insertion helis into hostile airspace
-- All draw from the per-side "heli" reserve (finite; recycled on RTB by supply.make_land_handler).
*/
import * as cs from "./campaign_state";
import type { WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as croute from "./croute";
import * as farpParking from "./farp_parking";
import * as ov from "./map_overlay";
import * as board from "./task_board";

const S = cs.S;
type LogFn = (message: string) => void;

import type { Side } from "./campaign_types";
import { BLUE, RED } from "./sides";

type Role = "anti_armour" | "hunter_killer" | "cas" | "bai";

interface AttackConfig {
	country: number;
	type: string;
	pylons: PylonData[];
	fuel: number;
}

const noop: LogFn = () => undefined;

// ── Attack helicopter roster (hoisted to config: attack_heli type + payloads.attack_heli pylons) ──
// fuel is a spawn-kinematics amount (not warzone type/economy data) → kept module-local per side.
const HELI_FUEL: Record<number, number> = {
	[BLUE]: 1600,
	[RED]: 1500,
};
const ATTACK: Record<number, AttackConfig> = {};
for (const side of [BLUE, RED]) {
	ATTACK[side] = {
		country: config.C.countries[side],
		type: config.C.types.aircraft[side].attack_heli,
		pylons: config.C.payloads[side].attack_heli,
		fuel: HELI_FUEL[side],
	};
}

// A section = 2 attack helis (draws 2 from the "heli" reserve). Used by build_attack_heli.
const SECTION_SIZE = 2;

// Attack profile: low and slow, nap-of-the-earth-ish.
const HELI_ALT = 60; // m AGL cruise
const HELI_SPEED = 55; // m/s ≈ 107 kt
const ENGAGE_DIST = 12000; // m; attack helis engage targets within this range

interface LaunchPosition {
	home?: Airbase;
	pos?: Vec3;
	id?: AirbaseId;
}

function launchPosition(baseName: string): LaunchPosition {
	const home = Airbase.getByName(baseName);
	if (home !== undefined) {
		return { home, pos: home.getPosition().p, id: home.getID() };
	}
	const bp = S.base_pos[baseName];
	if (bp === undefined) return {};
	let height = 0;
	const [ok, result] = pcall(() => land.getHeight({ x: bp.x, y: bp.z }));
	if (ok && result !== undefined) height = result;
	return { pos: { x: bp.x, y: height, z: bp.z } };
}

// BUILDER (task-board contract): the board already consumed SECTION_SIZE "heli" from baseName.
export function build_attack_heli(
	side: Side,
	baseName: string,
	targetPos: WorldPoint,
	role: Role,
	logFn: LogFn = noop,
): Group | undefined {
	const launch = launchPosition(baseName);
	const { home, pos: abPos, id: abId } = launch;
	if (abPos === undefined) {
		cs.dbg(
			"heli",
			"%s heli ABORT: base %s has no Airbase and no base_pos",
			cs.SIDE_NAME[side],
			baseName,
		);
		return undefined;
	}
	const cfg = ATTACK[side];
	const [bx, by] = cs.wp_xy(abPos);
	const tx = targetPos.x;
	const ty = targetPos.z;
	const sid = cs.next_id();
	const labels: Record<Role, string> = {
		anti_armour: "AA",
		hunter_killer: "HK",
		cas: "CAS",
		bai: "BAI",
	};
	const gname = string.format("Heli-%s-%d-%d", labels[role], side, sid);
	const targetTypes =
		role === "hunter_killer"
			? ["Ground Units", "Helicopters", "Air"]
			: ["Ground Units", "Helicopters"];

	const units: UnitData[] = [];
	for (let i = 1; i <= SECTION_SIZE; i += 1) {
		units.push({
			name: `${gname}-${i}`,
			type: cfg.type,
			skill: "High",
			x: abPos.x + (i - 1) * 40,
			y: abPos.z,
			alt: abPos.y,
			alt_type: "BARO",
			speed: 0,
			heading: cs.heading_to(abPos.x, abPos.z, targetPos.x, targetPos.z),
			payload: {
				fuel: cfg.fuel,
				flare: 60,
				chaff: 60,
				gun: 100,
				pylons: cfg.pylons,
			},
		});
	}

	const depart =
		abId !== undefined
			? {
					type: "TakeOffParkingHot",
					action: "From Parking Area Hot",
					airdromeId: abId,
					alt: abPos.y,
					alt_type: "BARO",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: bx,
					y: by,
					name: "Depart",
					formation_template: "",
				}
			: {
					type: "TakeOffGroundHot",
					action: "From Ground Area Hot",
					alt: abPos.y,
					alt_type: "BARO",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: bx,
					y: by,
					name: "Depart",
					formation_template: "",
				};
	const rtb =
		abId !== undefined
			? {
					type: "Land",
					action: "Landing",
					airdromeId: abId,
					alt: abPos.y,
					alt_type: "BARO",
					speed: HELI_SPEED,
					ETA: 0,
					ETA_locked: false,
					x: bx,
					y: by,
					name: "RTB",
					formation_template: "",
				}
			: {
					type: "Turning Point",
					action: "Turning Point",
					alt: HELI_ALT,
					alt_type: "RADIO",
					speed: HELI_SPEED,
					ETA: 0,
					ETA_locked: false,
					x: bx,
					y: by,
					name: "RTB",
					formation_template: "",
				};
	const spec: GroupData = {
		name: gname,
		task: "CAS",
		hidden: false,
		units,
		route: {
			points: croute.expand(
				[
					depart,
					{
						type: "Turning Point",
						action: "Turning Point",
						alt: HELI_ALT,
						alt_type: "RADIO",
						speed: HELI_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: tx,
						y: ty,
						name: "Engage",
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
										params: { maxDist: ENGAGE_DIST, priority: 0, targetTypes },
									},
								],
							},
						},
					},
					rtb,
				],
				side,
				{ alt: HELI_ALT, alt_type: "RADIO", speed: HELI_SPEED, name: "Nav" },
			),
		},
	};
	if (home !== undefined) {
		farpParking.configureDeparture(baseName, home, spec, depart);
		farpParking.configureLanding(baseName, home, rtb);
	}
	const [ok, group] = pcall(() =>
		coalition.addGroup(cfg.country, Group.Category.HELICOPTER, spec),
	);
	if (ok && group !== undefined) {
		ov.add_task_arrow(gname, abPos, targetPos, side);
		logFn(
			string.format(
				"%s %s heli section (%dx%s) from %s → (%.0f,%.0f)",
				cs.SIDE_NAME[side],
				role,
				SECTION_SIZE,
				cfg.type,
				baseName,
				targetPos.x,
				targetPos.z,
			),
		);
		cs.dbg(
			"heli",
			"%s %s heli section #%d queued from %s (ground_start=%s)",
			cs.SIDE_NAME[side],
			role,
			sid,
			baseName,
			tostring(home === undefined),
		);
		return group;
	}
	cs.dbg(
		"heli",
		"%s heli spawn FAILED at %s (type=%s ground_start=%s): pcall_ok=%s err=%s",
		cs.SIDE_NAME[side],
		baseName,
		cfg.type,
		tostring(home === undefined),
		tostring(ok),
		tostring(group),
	);
	return undefined;
}

function buildEscort(
	side: Side,
	baseName: string,
	targetPos: WorldPoint,
	logFn: LogFn,
): Group | undefined {
	const home = Airbase.getByName(baseName);
	if (home === undefined) {
		cs.dbg(
			"heli",
			"%s build_escort ABORT: base %s not found",
			cs.SIDE_NAME[side],
			baseName,
		);
		return undefined;
	}
	const cfg = ATTACK[side];
	const abPos = home.getPosition().p;
	const [bx, by] = cs.wp_xy(abPos);
	const tx = targetPos.x;
	const ty = targetPos.z;
	const sid = cs.next_id();
	const gname = string.format("Heli-ESC-%d-%d", side, sid);
	const spec: GroupData = {
		name: gname,
		task: "Escort",
		hidden: false,
		airdromeId: home.getID(),
		units: [
			{
				name: `${gname}-1`,
				type: cfg.type,
				skill: "High",
				x: abPos.x,
				y: abPos.z,
				alt: abPos.y,
				alt_type: "BARO",
				speed: 0,
				heading: cs.heading_to(abPos.x, abPos.z, targetPos.x, targetPos.z),
				payload: {
					fuel: cfg.fuel,
					flare: 60,
					chaff: 60,
					gun: 100,
					pylons: cfg.pylons,
				},
			},
		],
		route: {
			points: croute.expand(
				[
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
						alt: HELI_ALT,
						alt_type: "RADIO",
						speed: HELI_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: tx,
						y: ty,
						name: "Escort",
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
											maxDist: ENGAGE_DIST,
											priority: 0,
											targetTypes: ["Ground Units", "Helicopters", "Air"],
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
						speed: HELI_SPEED,
						ETA: 0,
						ETA_locked: false,
						x: bx,
						y: by,
						name: "RTB",
						formation_template: "",
					},
				],
				side,
				{ alt: HELI_ALT, alt_type: "RADIO", speed: HELI_SPEED, name: "Nav" },
			),
		},
	};
	const escortPoints = spec.route?.points;
	if (escortPoints !== undefined) {
		farpParking.configureDeparture(baseName, home, spec, escortPoints[0]);
		farpParking.configureLanding(
			baseName,
			home,
			escortPoints[escortPoints.length - 1],
		);
	}
	const [ok, group] = pcall(() =>
		coalition.addGroup(cfg.country, Group.Category.HELICOPTER, spec),
	);
	if (ok && group !== undefined) {
		logFn(
			string.format(
				"%s attack-heli escort #%d → (%.0f,%.0f)",
				cs.SIDE_NAME[side],
				sid,
				targetPos.x,
				targetPos.z,
			),
		);
		cs.dbg(
			"heli",
			"%s escort #%d queued from %s",
			cs.SIDE_NAME[side],
			sid,
			baseName,
		);
		return group;
	}
	cs.dbg(
		"heli",
		"%s escort #%d SPAWN FAILED from %s: pcall_ok=%s err=%s",
		cs.SIDE_NAME[side],
		sid,
		baseName,
		tostring(ok),
		tostring(group),
	);
	return undefined;
}

// spawn_escort — SINGLE-SHOT EXPORT (never-replace list).
export function spawn_escort(
	side: Side,
	targetPos: WorldPoint | undefined,
	logFn: LogFn = noop,
): boolean {
	if (targetPos === undefined) {
		cs.dbg("heli", "%s spawn_escort ABORT: no target_pos", cs.SIDE_NAME[side]);
		return false;
	}
	cs.dbg(
		"heli",
		"%s spawn_escort: queueing immediate escort task",
		cs.SIDE_NAME[side],
	);
	board.create_task({
		type: "heli_escort",
		side,
		count: 1,
		immediate: true,
		log_fn: logFn,
		target: { pos: targetPos },
		builder: (baseName: string) =>
			buildEscort(side, baseName, targetPos, logFn),
	});
	return true;
}
