/** @noSelfInFile */
/*
-- cas_bai_sead.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--
-- create_cas_tasks() line 815
--   Period: 6 min (skirmish) / 15 min (campaign); offset 0.0
--   Targets: LIST_TYPE_GROUND_REGISTRY groups where INT_TYPE_FRONTLINE==1 (highlevl.c:877)
--            → PRIMARY frontline group TYPE (armour), not a sector-distance value.
--   Score: (1-airdef)*1 + base_dist*3 + sector_ratio*2; max=6.0
--   Limits: CREATE_CAS_TASK_COUNT=2, MAX_SECTOR_CAS_TASK_COUNT=1
--   FOW: NO FOW check (CAS proceeds regardless of fog)
--
-- create_bai_tasks() line 575
--   Period: 10 min (skirmish) / 20 min (campaign); offset 90 s / 5 min
--   Targets: LIST_TYPE_GROUND_REGISTRY groups where INT_TYPE_FRONTLINE>1 (highlevl.c:637)
--            → SECONDARY(2)/support + ARTILLERY(3) group TYPES (second-line).
--   Score: (1-airdef)*2 + base_dist*3 + sector_ratio*2; max=7.0
--   Limits: CREATE_BAI_TASK_COUNT=2, MAX_SECTOR_BAI_TASK_COUNT=1
--   FOW: fow > 0.5 * maximum (CONFIRMED at line 757 — HIGHER threshold than other tasks)
--
-- ECHELON SPLIT (Cluster B): INT_TYPE_FRONTLINE is group_database[sub_type].frontline_flag
-- (gp_int.c:389-392) — a STATIC per-group-TYPE flag (NONE=0/PRIMARY=1/SECONDARY=2/ARTILLERY=3,
-- group.h:199-202), NOT a distance. The port's ground groups are undifferentiated, so the
-- echelon is proxied POSITIONALLY via frontline.echelon_of(pos): a target whose nearest owned
-- base is a Gabriel-frontline base → "frontline" (CAS), else → "second" (BAI/SEAD). See
-- frontline.lua:echelon_of. This is the first real consumer of the Gabriel frontline flags and
-- replaces the old invented `is_near_friendly` 200 km band (frontl.FRONTLINE_RADIUS, traced to
-- nothing in EECH) that starved BAI on any scoped theatre.
--
-- create_sead_tasks() line 1918
--   Period: 10 min (skirmish) / 12 min (campaign); offset 2 s / 3 min
--   Targets: enemy groups with air_attack_strength==10 AND !frontline_flag (highlevl.c:1981)
--            → rear/site AA (NONE echelon), not frontline-attached AA. Proxied via
--              frontline.echelon_of(pos)=="second".
--   Score: base_dist*4 + sector_ratio*3; max=7.0
--   Limits: CREATE_SEAD_TASK_COUNT=2, MAX_SECTOR_SEAD_TASK_COUNT=1
--   FOW: fow >= 0.25 * maximum
--
-- create_oca_sweep_tasks() line 1473
--   Period: 20 min (skirmish) / 30 min (campaign); offset 4 min / 1.5 min
--   Targets: enemy keysites where keysite_database[type].oca_target == true
--   Score: (1-airdef)*1 + base_dist*4 + sector_ratio*2; max=7.0
--   Limits: CREATE_OCA_SWEEP_TASK_COUNT=2, MIN_TASK_CREATION_RATIO=0.75
--   FOW: fow >= 0.25 * maximum
--
-- create_artillery_strike_tasks() line 2836
--   Period: 12 min (skirmish) / 15 min (campaign); offset 8 s / 45 s
--   Groups: own artillery groups (GROUP_FRONTLINE_FLAG_ARTILLERY)
--   Targets: enemy frontline groups + ground_strike keysites within max_weapon_range
--   FOW: fow > 0.25 * maximum (per target sector)
--   Limit: MAX_ARTILLERY_STRIKE_COUNT=5
--
-- highlevl.c line 84-100 constants:
--   MAX_HIGHLEVEL_TARGET_CHECKS = 160
--   MIN_TASK_CREATION_RATIO     = 0.75
--   CREATE_CAS_TASK_COUNT       = 2
--   MAX_SECTOR_CAS_TASK_COUNT   = 1
--   CREATE_BAI_TASK_COUNT       = 2
--   MAX_SECTOR_BAI_TASK_COUNT   = 1
--   CREATE_OCA_SWEEP_TASK_COUNT = 2
--   CREATE_SEAD_TASK_COUNT      = 2
--   MAX_SECTOR_SEAD_TASK_COUNT  = 1
--   MAX_ARTILLERY_STRIKE_COUNT  = 5 (line 2836)
*/

import * as mode from "./campaign_mode";
import { matches } from "./lua_interop";
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as croute from "./croute";
import * as fow from "./fog_of_war";
import * as frontline from "./frontline";
import * as imap from "./imap";
import * as installations from "./installations";
import * as overlay from "./map_overlay";
import * as recon from "./recon";
import * as supply from "./supply";
import * as board from "./task_board";

const S = cs.S;
type LogFn = (message: string) => void;
interface Rated {
	name?: string;
	pos: WorldPoint;
	group?: Group;
	rating: number;
}
interface AircraftConfig {
	country: number;
	striker: string;
	escort: string;
}
interface HeliWar {
	build_attack_heli(
		this: void,
		side: Side,
		base: string,
		pos: WorldPoint,
		role: "cas" | "bai",
		logFn: LogFn,
	): Group | undefined;
}
interface Reaction {
	on_artillery_fire(
		this: void,
		side: Side,
		group: Group,
		pos: WorldPoint,
		logFn: LogFn,
	): void;
}

const MAX_HIGHLEVEL_TARGET_CHECKS = 160,
	MIN_TASK_CREATION_RATIO = 0.75;
const CREATE_CAS_TASK_COUNT = 2,
	MAX_SECTOR_CAS_TASK_COUNT = 1;
const CREATE_BAI_TASK_COUNT = 2,
	MAX_SECTOR_BAI_TASK_COUNT = 1;
const CREATE_OCA_SWEEP_TASK_COUNT = 2,
	CREATE_SEAD_TASK_COUNT = 2,
	MAX_SECTOR_SEAD_TASK_COUNT = 1;
const MAX_SECTOR_OCA_SWEEP_TASK_COUNT = 1;
const MAX_ARTILLERY_STRIKE_COUNT = 5;
const FOW_THRESHOLD_BAI = 0.5,
	FOW_THRESHOLD_SEAD = 0.25,
	FOW_THRESHOLD_OCA = 0.25,
	FOW_THRESHOLD_ART = 0.25;
const PERIOD_CAS = mode.SCHED.cas.period,
	PERIOD_BAI = mode.SCHED.bai.period,
	PERIOD_SEAD = mode.SCHED.sead.period;
const PERIOD_OCA_SWEEP = mode.SCHED.oca_sweep.period,
	PERIOD_ARTY = mode.SCHED.artillery.period;
const OFFSET_CAS = 0,
	OFFSET_BAI = 5 * 60,
	OFFSET_SEAD = 3 * 60,
	OFFSET_OCA_SWEEP = 1.5 * 60,
	OFFSET_ARTY = 45;
const STRIKE_ALTITUDE_METRES = 6000,
	ESCORT_ALTITUDE_METRES = 7000,
	STRIKE_SPEED_METRES_PER_SECOND = 220,
	SECTOR_RATIO_RADIUS_METRES = 200000;
// Verified score coefficients from highlevl.c task generators cited in the module header.
const CAS_AIR_DEFENCE_WEIGHT = 1,
	CAS_BASE_DISTANCE_WEIGHT = 3,
	CAS_SECTOR_RATIO_WEIGHT = 2;
const BAI_AIR_DEFENCE_WEIGHT = 2,
	BAI_BASE_DISTANCE_WEIGHT = 3,
	BAI_SECTOR_RATIO_WEIGHT = 2;
const SEAD_BASE_DISTANCE_WEIGHT = 4,
	SEAD_SECTOR_RATIO_WEIGHT = 3;
const OCA_AIR_DEFENCE_WEIGHT = 1,
	OCA_BASE_DISTANCE_WEIGHT = 4,
	OCA_SECTOR_RATIO_WEIGHT = 2;
// group.h:199-202 enum ordinals; kept named because zero is a valid NONE value.
const FRONTLINE_FLAG_NONE = 0,
	FRONTLINE_FLAG_PRIMARY = 1,
	FRONTLINE_FLAG_SECONDARY = 2;
// DCS adapter flight/task parameters (metres, metres/second, kilograms, and item counts).
const AIRCRAFT_SPAWN_SPACING_METRES = 20;
const ESCORT_ENGAGEMENT_RANGE_METRES = 40000;
const STRIKE_ENGAGEMENT_RANGE_METRES = 15000;
const ESCORT_FUEL_KILOGRAMS = 5200;
const STRIKER_FUEL_KILOGRAMS = 4900;
const ESCORT_COUNTERMEASURE_COUNT = 120;
const STRIKER_COUNTERMEASURE_COUNT = 60;
const PAYLOAD_GUN_PERCENT = 100;
const MIN_SCHEDULER_DELAY_SECONDS = 1;
const AC: Record<number, AircraftConfig> = {};
for (const side of [coalition.side.BLUE, coalition.side.RED])
	AC[side] = {
		country: config.C.countries[side],
		striker: config.C.types.aircraft[side].striker,
		escort: config.C.types.aircraft[side].escort,
	};
const PYLON = config.C.payloads;

function sectorRatio(pos: WorldPoint, side: Side): number {
	let friendly = 0,
		total = 0;
	const radius2 = SECTOR_RATIO_RADIUS_METRES ** 2;
	for (const [name, owner] of Object.entries(S.base_owner)) {
		const base = S.base_pos[name];
		if (base === undefined) continue;
		const dx = pos.x - base.x,
			dz = pos.z - base.z;
		if (dx * dx + dz * dz <= radius2) {
			total += 1;
			if (owner === side) friendly += 1;
		}
	}
	return total === 0 ? 0 : friendly / total;
}
function nearestBase(pos: WorldPoint): string | undefined {
	let best: string | undefined,
		distance = math.huge;
	for (const [name, base] of Object.entries(S.base_pos)) {
		const dx = pos.x - base.x,
			dz = pos.z - base.z,
			d2 = dx * dx + dz * dz;
		if (d2 < distance) {
			distance = d2;
			best = name;
		}
	}
	return best;
}
function fowAt(pos: WorldPoint, side: Side): number {
	const base = nearestBase(pos);
	return base === undefined ? 0 : (fow.get(base, side) ?? 0);
}
function aaUnit(unit: Unit): boolean {
	const a = unit.getDesc().attributes;
	return (
		a?.["SAM"] === true ||
		a?.["AAA"] === true ||
		a?.["SR SAM"] === true ||
		a?.["MR SAM"] === true ||
		a?.["LR SAM"] === true ||
		a?.["IR Guided SAM"] === true
	);
}
function groupFlag(group: Group): number | undefined {
	const name = group.getName();
	if (matches(name, "^GndCol%-")) return FRONTLINE_FLAG_PRIMARY;
	if (
		matches(name, "^GndSec%-") ||
		matches(name, "^Arty%-") ||
		matches(name, "%-def$")
	)
		return FRONTLINE_FLAG_SECONDARY;
	if (matches(name, "^Patrol%-") || matches(name, "^FP%-"))
		return FRONTLINE_FLAG_NONE;
	return undefined;
}
function echelon(entry: Rated): "frontline" | "second" | "none" {
	const flag = entry.group !== undefined ? groupFlag(entry.group) : undefined;
	if (flag === FRONTLINE_FLAG_PRIMARY) return "frontline";
	if (flag !== undefined)
		return flag >= FRONTLINE_FLAG_SECONDARY ? "second" : "none";
	return frontline.echelon_of(entry.pos);
}
function groundTargets(attackerSide: Side): Rated[] {
	const out: Rated[] = [];
	for (const group of coalition.getGroups(cs.ENEMY[attackerSide]) ?? []) {
		if (
			out.length >= MAX_HIGHLEVEL_TARGET_CHECKS ||
			!group.isExist() ||
			group.getCategory() !== Group.Category.GROUND
		)
			continue;
		const unit = group.getUnit(1);
		if (unit === undefined || !unit.isExist()) continue;
		if (groupFlag(group) !== undefined || !aaUnit(unit))
			out.push({ group, pos: unit.getPosition().p, rating: 0 });
	}
	return out;
}
function aaTargets(targetSide: Side): Rated[] {
	const out: Rated[] = [];
	for (const group of coalition.getGroups(targetSide) ?? []) {
		if (
			out.length >= MAX_HIGHLEVEL_TARGET_CHECKS ||
			!group.isExist() ||
			groupFlag(group) !== undefined
		)
			continue;
		const unit = group.getUnit(1);
		if (unit !== undefined && unit.isExist() && aaUnit(unit))
			out.push({ group, pos: unit.getPosition().p, rating: 0 });
	}
	return out;
}

function spawnSeadEscort(
	side: Side,
	home: Airbase,
	basePos: Vec3,
	target: WorldPoint,
	count: number,
	_logFn: LogFn,
): void {
	if (count <= 0) return;
	const baseName = home.getName();
	if (!supply.consume_base(baseName, "escort", count)) {
		cs.dbg(
			"sead",
			"%s SEAD escort ABORT at %s: no escort stock",
			cs.SIDE_NAME[side],
			baseName,
		);
		return;
	}
	const cfg = AC[side],
		[bx, by] = cs.wp_xy(basePos),
		[tx, ty] = cs.wp_xy(target);
	const id = cs.next_id(),
		name = string.format("Escort-%d", id),
		units: UnitData[] = [];
	for (let i = 1; i <= count; i += 1)
		units.push({
			name: `${name}-${i}`,
			type: cfg.escort,
			skill: "High",
			x: basePos.x + (i - 1) * AIRCRAFT_SPAWN_SPACING_METRES,
			y: basePos.z,
			alt: basePos.y,
			alt_type: "BARO",
			speed: 0,
			heading: 0,
			payload: {
				fuel: ESCORT_FUEL_KILOGRAMS,
				flare: ESCORT_COUNTERMEASURE_COUNT,
				chaff: ESCORT_COUNTERMEASURE_COUNT,
				gun: PAYLOAD_GUN_PERCENT,
				pylons: PYLON[side].escort,
			},
		});
	const [ok, group] = pcall(() =>
		coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
			name,
			task: "Fighter Sweep",
			hidden: false,
			airdromeId: home.getID(),
			units,
			route: {
				points: croute.expand(
					[
						{
							type: "TakeOffParkingHot",
							action: "From Parking Area Hot",
							airdromeId: home.getID(),
							alt: basePos.y,
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
							alt: ESCORT_ALTITUDE_METRES,
							alt_type: "BARO",
							speed: STRIKE_SPEED_METRES_PER_SECOND,
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
											params: {
												maxDist: ESCORT_ENGAGEMENT_RANGE_METRES,
												priority: 0,
												targetTypes: ["Air"],
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
							alt: basePos.y,
							alt_type: "BARO",
							speed: STRIKE_SPEED_METRES_PER_SECOND,
							ETA: 0,
							ETA_locked: false,
							x: bx,
							y: by,
							name: "RTB",
							formation_template: "",
						},
					],
					side,
					{
						alt: ESCORT_ALTITUDE_METRES,
						alt_type: "BARO",
						speed: STRIKE_SPEED_METRES_PER_SECOND,
						name: "Nav",
					},
				),
			},
		}),
	);
	if (ok && group !== undefined) {
		cs.dbg(
			"sead",
			"%s SEAD escort #%d (%dx%s) spawned from %s",
			cs.SIDE_NAME[side],
			id,
			count,
			cfg.escort,
			baseName,
		);
	} else {
		supply.recycle_base(baseName, "escort", count);
		cs.dbg(
			"sead",
			"%s SEAD escort #%d FAILED (pcall_ok=%s) -> refunded",
			cs.SIDE_NAME[side],
			id,
			tostring(ok),
		);
	}
}

interface CandidateDispatchConfig {
	count: number;
	sectorMax: number;
	threshold?: number;
	strict?: boolean;
	side: Side;
	label: string;
	logFn: LogFn;
	spawn(this: void, entry: Rated): boolean;
	objective?(
		this: void,
		entry: Rated,
	): { kind: string; base?: string; group?: Group; pos?: WorldPoint };
}
function dispatchRatedCandidates(
	rated: Rated[],
	cfg: CandidateDispatchConfig,
): void {
	rated.sort((a, b) => b.rating - a.rating);
	if (rated.length === 0 || rated[0].rating <= 0) return;
	const used: Record<string, number> = {};
	for (let i = 0; i < Math.min(rated.length, cfg.count); i += 1) {
		const entry = rated[i];
		if (entry.rating / rated[0].rating < MIN_TASK_CREATION_RATIO) continue;
		const base = nearestBase(entry.pos),
			key = base ?? tostring(i),
			count = used[key] ?? 0;
		if (count >= cfg.sectorMax) continue;
		let ok: boolean;
		if (cfg.threshold === undefined) ok = cfg.spawn(entry);
		else {
			const value = fowAt(entry.pos, cfg.side);
			const pass = cfg.strict ? value > cfg.threshold : value >= cfg.threshold;
			const reconPoint = base !== undefined ? S.base_pos[base] : entry.pos;
			ok = pass
				? cfg.spawn(entry)
				: recon.spawn_recon(
						cfg.side,
						{ x: reconPoint.x, y: reconPoint.y ?? 0, z: reconPoint.z },
						cfg.label,
						cfg.logFn,
						cfg.objective?.(entry),
					);
		}
		if (ok) used[key] = count + 1;
	}
}

function strikeBuilder(
	side: Side,
	baseName: string,
	target: WorldPoint,
	label: string,
	logFn: LogFn,
): Group | undefined {
	const home = Airbase.getByName(baseName);
	if (home === undefined) return undefined;
	const cfg = AC[side],
		pos = home.getPosition().p,
		[bx, by] = cs.wp_xy(pos),
		id = cs.next_id();
	const name = string.format("%s-%d-%d", label, side, id),
		isSead = matches(label, "SEAD");
	const group = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
		name,
		task: isSead ? "SEAD" : "Ground Attack",
		hidden: false,
		airdromeId: home.getID(),
		units: [
			{
				name: `${name}-1`,
				type: cfg.striker,
				skill: "Good",
				x: pos.x,
				y: pos.z,
				alt: pos.y,
				alt_type: "BARO",
				speed: 0,
				heading: cs.heading_to(pos.x, pos.z, target.x, target.z),
				payload: {
					fuel: STRIKER_FUEL_KILOGRAMS,
					flare: STRIKER_COUNTERMEASURE_COUNT,
					chaff: STRIKER_COUNTERMEASURE_COUNT,
					gun: PAYLOAD_GUN_PERCENT,
					pylons: PYLON[side].striker,
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
						alt: pos.y,
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
						alt: STRIKE_ALTITUDE_METRES,
						alt_type: "BARO",
						speed: STRIKE_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						x: target.x,
						y: target.z,
						name: "Attack",
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
											maxDist: STRIKE_ENGAGEMENT_RANGE_METRES,
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
						alt: pos.y,
						alt_type: "BARO",
						speed: STRIKE_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						x: bx,
						y: by,
						name: "RTB",
						formation_template: "",
					},
				],
				side,
				{
					alt: STRIKE_ALTITUDE_METRES,
					alt_type: "BARO",
					speed: STRIKE_SPEED_METRES_PER_SECOND,
					name: "Nav",
				},
			),
		},
	});
	if (group !== undefined) {
		overlay.add_task_arrow(name, pos, target, side);
		if (isSead)
			spawnSeadEscort(
				side,
				home,
				pos,
				target,
				cs.escort_count("sead", side, pos, target, logFn),
				logFn,
			);
		logFn(
			string.format(
				"%s %s #%d from %s",
				cs.SIDE_NAME[side],
				label,
				id,
				home.getName(),
			),
		);
	}
	return group;
}

function createStrike(
	side: Side,
	target: WorldPoint,
	type: "cas" | "bai" | "sead",
	label: string,
	logFn: LogFn,
	immediate = false,
	critical?: boolean,
): boolean {
	const builder =
		type === "sead"
			? (base: string) => strikeBuilder(side, base, target, label, logFn)
			: (base: string) =>
					require<HeliWar>("heli_war").build_attack_heli(
						side,
						base,
						target,
						type,
						logFn,
					);
	board.create_task({
		type,
		side,
		count: 1,
		log_fn: logFn,
		immediate,
		critical,
		target: { pos: target },
		builder: (base) => builder(base),
	});
	return true;
}

function runCas(side: Side, logFn: LogFn): void {
	const rated: Rated[] = [];
	for (const target of groundTargets(side))
		if (echelon(target) === "frontline") {
			target.rating =
				(1 - imap.get(side, imap.AIR_DEFENCE, target.pos)) *
					CAS_AIR_DEFENCE_WEIGHT +
				imap.get(side, imap.BASE_DISTANCE, target.pos) *
					CAS_BASE_DISTANCE_WEIGHT +
				sectorRatio(target.pos, side) * CAS_SECTOR_RATIO_WEIGHT;
			if (target.rating > 0) rated.push(target);
		}
	dispatchRatedCandidates(rated, {
		count: CREATE_CAS_TASK_COUNT,
		sectorMax: MAX_SECTOR_CAS_TASK_COUNT,
		side,
		label: "CAS",
		logFn,
		spawn: (e) => createStrike(side, e.pos, "cas", "CAS", logFn),
	});
}
function runBai(side: Side, logFn: LogFn): void {
	const rated: Rated[] = [];
	for (const target of groundTargets(side))
		if (echelon(target) === "second") {
			target.rating =
				(1 - imap.get(side, imap.AIR_DEFENCE, target.pos)) *
					BAI_AIR_DEFENCE_WEIGHT +
				imap.get(side, imap.BASE_DISTANCE, target.pos) *
					BAI_BASE_DISTANCE_WEIGHT +
				sectorRatio(target.pos, side) * BAI_SECTOR_RATIO_WEIGHT;
			if (target.rating > 0) rated.push(target);
		}
	dispatchRatedCandidates(rated, {
		count: CREATE_BAI_TASK_COUNT,
		sectorMax: MAX_SECTOR_BAI_TASK_COUNT,
		threshold: FOW_THRESHOLD_BAI,
		strict: true,
		side,
		label: "BAI",
		logFn,
		spawn: (e) => createStrike(side, e.pos, "bai", "BAI", logFn),
		objective: (e) => ({ kind: "frontline_group", pos: e.pos, group: e.group }),
	});
}
function runSead(side: Side, logFn: LogFn): void {
	const rated: Rated[] = [];
	for (const target of aaTargets(cs.ENEMY[side]))
		if (echelon(target) === "second") {
			target.rating =
				imap.get(side, imap.BASE_DISTANCE, target.pos) *
					SEAD_BASE_DISTANCE_WEIGHT +
				sectorRatio(target.pos, side) * SEAD_SECTOR_RATIO_WEIGHT;
			if (target.rating > 0) rated.push(target);
		}
	dispatchRatedCandidates(rated, {
		count: CREATE_SEAD_TASK_COUNT,
		sectorMax: MAX_SECTOR_SEAD_TASK_COUNT,
		threshold: FOW_THRESHOLD_SEAD,
		side,
		label: "SEAD",
		logFn,
		spawn: (e) => createStrike(side, e.pos, "sead", "SEAD", logFn),
		objective: (e) => ({ kind: "aa_group", pos: e.pos, group: e.group }),
	});
}

function scheduleGenerator(
	side: Side,
	offset: number,
	period: number,
	label: string,
	fn: (side: Side, logFn: LogFn) => void,
	logFn: LogFn,
): void {
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => fn(side, logFn));
			if (!ok) logFn(`${label} error: ${tostring(error)}`);
			return time + period;
		},
		undefined,
		timer.getTime() + Math.max(offset, MIN_SCHEDULER_DELAY_SECONDS),
	);
}
export function schedule_cas(
	side: Side,
	initialOffset = OFFSET_CAS,
	logFn: LogFn = () => undefined,
): void {
	scheduleGenerator(side, initialOffset, PERIOD_CAS, "CAS", runCas, logFn);
}
export function schedule_bai(
	side: Side,
	initialOffset = OFFSET_BAI,
	logFn: LogFn = () => undefined,
): void {
	scheduleGenerator(side, initialOffset, PERIOD_BAI, "BAI", runBai, logFn);
}
export function schedule_sead(
	side: Side,
	initialOffset = OFFSET_SEAD,
	logFn: LogFn = () => undefined,
): void {
	scheduleGenerator(side, initialOffset, PERIOD_SEAD, "SEAD", runSead, logFn);
}

export function spawn_sead_against(
	side: Side,
	group: Group | undefined,
	logFn: LogFn = () => undefined,
	critical?: boolean,
): boolean {
	const unit = group?.isExist() ? group.getUnit(1) : undefined;
	return unit !== undefined && unit.isExist()
		? createStrike(
				side,
				unit.getPosition().p,
				"sead",
				"SEAD-React",
				logFn,
				true,
				critical,
			)
		: false;
}
export function spawn_bai_against(
	side: Side,
	pos: WorldPoint | undefined,
	logFn: LogFn = () => undefined,
	critical?: boolean,
): boolean {
	return pos !== undefined
		? createStrike(side, pos, "bai", "BAI-React", logFn, true, critical)
		: false;
}

function buildSweep(
	side: Side,
	baseName: string,
	target: WorldPoint,
	targetName: string,
	logFn: LogFn,
): Group | undefined {
	const home = Airbase.getByName(baseName);
	if (home === undefined) return undefined;
	const cfg = AC[side],
		pos = home.getPosition().p,
		[bx, by] = cs.wp_xy(pos),
		id = cs.next_id();
	const name = string.format("OCA-Sweep-%d-%d", side, id);
	const group = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
		name,
		task: "Fighter Sweep",
		hidden: false,
		airdromeId: home.getID(),
		units: [
			{
				name: `${name}-1`,
				type: cfg.escort,
				skill: "High",
				x: pos.x,
				y: pos.z,
				alt: pos.y,
				alt_type: "BARO",
				speed: 0,
				heading: 0,
				payload: {
					fuel: ESCORT_FUEL_KILOGRAMS,
					flare: ESCORT_COUNTERMEASURE_COUNT,
					chaff: ESCORT_COUNTERMEASURE_COUNT,
					gun: PAYLOAD_GUN_PERCENT,
					pylons: PYLON[side].escort,
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
						alt: pos.y,
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
						alt: ESCORT_ALTITUDE_METRES,
						alt_type: "BARO",
						speed: STRIKE_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						x: target.x,
						y: target.z,
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
										params: {
											maxDist: ESCORT_ENGAGEMENT_RANGE_METRES,
											priority: 0,
											targetTypes: ["Air"],
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
						alt: pos.y,
						alt_type: "BARO",
						speed: STRIKE_SPEED_METRES_PER_SECOND,
						ETA: 0,
						ETA_locked: false,
						x: bx,
						y: by,
						name: "RTB",
						formation_template: "",
					},
				],
				side,
				{
					alt: ESCORT_ALTITUDE_METRES,
					alt_type: "BARO",
					speed: STRIKE_SPEED_METRES_PER_SECOND,
					name: "Nav",
				},
			),
		},
	});
	if (group !== undefined) {
		cs.register_task(name, {
			task_type: "oca_sweep",
			side,
			target_base: targetName,
			target_pos: target,
			objective: { kind: "keysite", base: targetName },
			born_time: timer.getTime(),
		});
		overlay.add_task_arrow(name, pos, target, side);
		logFn(
			string.format(
				"%s OCA Sweep #%d from %s → %s",
				cs.SIDE_NAME[side],
				id,
				home.getName(),
				targetName,
			),
		);
	}
	return group;
}
function createSweep(
	side: Side,
	target: WorldPoint,
	name: string,
	logFn: LogFn,
): boolean {
	board.create_task({
		type: "oca_sweep",
		side,
		count: 1,
		log_fn: logFn,
		target: {
			base: name,
			pos: target,
			objective: { kind: "keysite", base: name },
		},
		builder: (base) => buildSweep(side, base, target, name, logFn),
	});
	return true;
}
function runSweep(side: Side, logFn: LogFn): void {
	const rated: Rated[] = [];
	for (const [name, owner] of Object.entries(S.base_owner))
		if (owner === cs.ENEMY[side]) {
			const pos = S.base_pos[name];
			if (pos === undefined) continue;
			const rating =
				(1 - imap.get(side, imap.AIR_DEFENCE, pos)) * OCA_AIR_DEFENCE_WEIGHT +
				imap.get(side, imap.BASE_DISTANCE, pos) * OCA_BASE_DISTANCE_WEIGHT +
				sectorRatio(pos, side) * OCA_SECTOR_RATIO_WEIGHT;
			if (rating > 0) rated.push({ name, pos, rating });
		}
	dispatchRatedCandidates(rated, {
		count: CREATE_OCA_SWEEP_TASK_COUNT,
		sectorMax: MAX_SECTOR_OCA_SWEEP_TASK_COUNT,
		threshold: FOW_THRESHOLD_OCA,
		side,
		label: "OCA-Sweep",
		logFn,
		spawn: (e) =>
			e.name !== undefined && createSweep(side, e.pos, e.name, logFn),
		objective: (e) => ({ kind: "keysite", base: e.name, pos: e.pos }),
	});
}
export function run_oca_sweep(
	side: Side,
	logFn: LogFn = () => undefined,
	targetName?: string,
	targetPos?: WorldPoint,
): void {
	if (targetName !== undefined) {
		const pos = targetPos ?? S.base_pos[targetName];
		if (pos !== undefined) createSweep(side, pos, targetName, logFn);
	} else runSweep(side, logFn);
}
export function schedule_oca_sweep(
	side: Side,
	initialOffset = OFFSET_OCA_SWEEP,
	logFn: LogFn = () => undefined,
): void {
	scheduleGenerator(
		side,
		initialOffset,
		PERIOD_OCA_SWEEP,
		"OCA Sweep",
		runSweep,
		logFn,
	);
}

// DCS adapter defaults: representative mobile-artillery reach and FireAtPoint task parameters.
const ARTY_DEFAULT_RANGE_METRES = 20000;
const ARTY_IMPACT_RADIUS_METRES = 1000;
const ARTY_ROUND_COUNT = 20;
function runArtillery(side: Side, logFn: LogFn): void {
	const enemy = cs.ENEMY[side],
		artillery: Group[] = [],
		targets: WorldPoint[] = [];
	for (const group of coalition.getGroups(side) ?? []) {
		const unit = group.isExist() ? group.getUnit(1) : undefined;
		if (
			unit !== undefined &&
			unit.isExist() &&
			(unit.getDesc().attributes?.["Artillery"] === true ||
				matches(group.getName(), "^Arty"))
		)
			artillery.push(group);
	}
	for (const record of Object.values(S.ground_groups[enemy])) {
		const unit = cs.group_is_alive(record.grp)
			? record.grp.getUnit(1)
			: undefined;
		if (unit !== undefined && unit.isExist())
			targets.push(unit.getPosition().p);
	}
	for (const record of Object.values(S.arty_groups[enemy])) {
		const unit = cs.group_is_alive(record.grp)
			? record.grp.getUnit(1)
			: undefined;
		if (unit !== undefined && unit.isExist())
			targets.push(unit.getPosition().p);
	}
	for (const target of installations.strike_targets(side))
		targets.push(target.pos);
	for (const [name, owner] of Object.entries(S.base_owner))
		if (owner === enemy && S.base_pos[name] !== undefined)
			targets.push(S.base_pos[name]);
	let assigned = 0;
	for (const group of artillery) {
		if (assigned >= MAX_ARTILLERY_STRIKE_COUNT) break;
		const unit = group.getUnit(1);
		if (unit === undefined || !unit.isExist()) continue;
		const origin = unit.getPosition().p;
		for (const target of targets) {
			const dx = origin.x - target.x,
				dz = origin.z - target.z;
			if (dx * dx + dz * dz >= ARTY_DEFAULT_RANGE_METRES ** 2) continue;
			let visible = false;
			for (const [baseName, owner] of Object.entries(S.base_owner)) {
				const base = S.base_pos[baseName];
				if (owner !== enemy || base === undefined) continue;
				const bdx = target.x - base.x,
					bdz = target.z - base.z;
				if (
					bdx * bdx + bdz * bdz < SECTOR_RATIO_RADIUS_METRES ** 2 &&
					fow.get(baseName, side) > FOW_THRESHOLD_ART
				) {
					visible = true;
					break;
				}
			}
			if (!visible) continue;
			group.getController().setTask({
				id: "FireAtPoint",
				params: {
					point: { x: target.x, y: target.z },
					radius: ARTY_IMPACT_RADIUS_METRES,
					expendQty: ARTY_ROUND_COUNT,
					expendQtyEnabled: true,
				},
			});
			assigned += 1;
			logFn(
				string.format(
					"%s Artillery → (%.0f, %.0f)",
					cs.SIDE_NAME[side],
					target.x,
					target.z,
				),
			);
			const [ok, reaction] = pcall(() => require<Reaction>("reaction"));
			if (ok && reaction !== undefined)
				pcall(() => reaction.on_artillery_fire(enemy, group, origin, logFn));
			break;
		}
	}
}
export function schedule_artillery(
	side: Side,
	initialOffset = OFFSET_ARTY,
	logFn: LogFn = () => undefined,
): void {
	scheduleGenerator(
		side,
		initialOffset,
		PERIOD_ARTY,
		"Artillery",
		runArtillery,
		logFn,
	);
}
