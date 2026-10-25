/** @noSelfInFile */
/*
-- reaction.lua
-- EECH source: aphavoc/source/ai/highlevl/reaction.c
--
-- create_task_assigned_reactionary_tasks (line 97): on an OFFENSIVE keysite task being assigned
--   (GROUND_STRIKE / OCA_STRIKE / OCA_SWEEP / RECON), the OBJECTIVE side scrambles defensive air:
--   create_reaction_to_offensive_keysite_task_assigned (line 217):
--     if keysite requires_cap  and not already CAP-tasked  → create_cap_task   (CAP_DURATION)
--     if keysite requires_barcap and not already BARCAP-tasked → create_barcap_task at
--        objective + normalise(attacker - objective) * BARCAP_OFFSET (CAP_DURATION)
--
-- create_task_completed_reactionary_tasks (line 152): on RECON/BDA/STRIKE completing with SUCCESS:
--   create_reaction_to_recon_task_completed (line 314):
--     KEYSITE objective:
--       if create_sead_tasks_around_keysite() > 1 → BREAK (suppress: strike into SAMs aborted)
--       if ALIVE:
--         if troop_insertion_target and eff < min and not tasked → T.I. (+ backup defender T.I.)
--         if oca_target      → OCA_STRIKE (dedup) + OCA_SWEEP (dedup)
--         if ground_strike_target and eff >= min → GROUND_STRIKE
--     GROUP objective:
--       ANTI_AIRCRAFT group → create_sead_task
--       frontline group     → create_bai_task
--   create_reaction_to_strike_task_completed (line 609):
--     if ground_strike_target and eff >= min → another GROUND_STRIKE ; else if recon_target → BDA
--
-- Constants (reaction.c): BARCAP_OFFSET = 6.0*KILOMETRE = 6000 m (line 293);
--   CAP_DURATION = 30.0*ONE_MINUTE = 1800 s (lines 248/298).
--
-- DCS mapping. "task assigned" = S_EVENT_BIRTH of the mission group; "task completed SUCCESS" =
-- the mission group RTBs (S_EVENT_LAND) — a shot-down mission never lands, so it is a FAILURE and
-- triggers NO follow-on (this is the H1 fix: the old port fired follow-ons on group WIPEOUT, which
-- is EECH's failure case, not success). Every mission registers its exact objective in
-- campaign_state.active_tasks at spawn, so reactions target the RIGHT keysite (H5 fix), not the
-- base nearest the attacker's launch field.
*/
import * as aircraft from "./aircraft_lifecycle";
import * as cs from "./campaign_state";
import type { Side, TaskInfo, WorldPoint } from "./campaign_types";
import * as config from "./config";
import * as farpParking from "./farp_parking";
import * as fow from "./fog_of_war";
import * as imap from "./imap";
import * as installations from "./installations";
import * as keysite from "./keysite";
import { BLUE, RED } from "./sides";
import * as supply from "./supply";

const S = cs.S;
type LogFn = (message: string) => void;
interface Flags {
	requires_cap: boolean;
	requires_barcap: boolean;
	oca_target: boolean;
	ground_strike_target: boolean;
	troop_insertion_target: boolean;
	recon_target: boolean;
}
interface AircraftConfig {
	country: number;
	escort: string;
	heli: string;
}
interface CasModule {
	spawn_sead_against(
		this: void,
		side: Side,
		group: Group,
		logFn: LogFn,
		critical?: boolean,
	): boolean;
	spawn_bai_against(
		this: void,
		side: Side,
		pos: WorldPoint,
		logFn: LogFn,
		critical?: boolean,
	): boolean;
	run_oca_sweep(
		this: void,
		side: Side,
		logFn: LogFn,
		name?: string,
		pos?: WorldPoint,
	): void;
}
interface TroopModule {
	run_troop_insertion(
		this: void,
		side: Side,
		logFn: LogFn,
		name?: string,
	): void;
}
interface Pilots {
	on_birth(this: void, event: DcsEvent): void;
	on_debrief(
		this: void,
		unit: DcsObject,
		task: TaskInfo,
		result: { result: string; rating: number },
	): void;
	on_death(this: void, event: DcsEvent): void;
	on_hit(this: void, event: DcsEvent): void;
}

// Verified in reaction.c:247-298 and highlevl.c:2572-2574.
const BARCAP_OFFSET_METRES = 6000,
	CAP_DURATION_SECONDS = 1800,
	KEYSITE_SEAD_RANGE_METRES = 4000,
	MAX_KEYSITE_SEAD_TASKS = 3;
// DCS adapter flight/task parameters (metres, metres/second, kilograms, and item counts).
const CAP_ALTITUDE_METRES = 7000;
const CAP_SPEED_METRES_PER_SECOND = 250;
const CAP_ENGAGEMENT_RANGE_METRES = 60000;
const CAP_ORBIT_LEG_METRES = 18000;
const ESCORT_FUEL_KILOGRAMS = 5200;
const ESCORT_COUNTERMEASURE_COUNT = 120;
const BDA_ALTITUDE_METRES = 300;
const BDA_SPEED_METRES_PER_SECOND = 60;
const BDA_FUEL_KILOGRAMS = 2200;
const BDA_COUNTERMEASURE_COUNT = 60;
const PAYLOAD_GUN_PERCENT = 100;
// reaction.c:386 and :780 thresholds; keysite SEAD is suppressed after more than one task.
const KEYSITE_SEAD_FOW_THRESHOLD = 0.25;
const KEYSITE_SEAD_SUPPRESSION_COUNT = 1;
const COUNTER_BATTERY_FOW_THRESHOLD = 0.5;
const COUNTER_BATTERY_BASE_DISTANCE_WEIGHT = 2;
const AIRBASE_FLAGS: Flags = {
	requires_cap: true,
	requires_barcap: false,
	oca_target: true,
	ground_strike_target: true,
	troop_insertion_target: true,
	recon_target: true,
};
const FARP_FLAGS: Flags = {
	requires_cap: true,
	requires_barcap: false,
	oca_target: false,
	ground_strike_target: true,
	troop_insertion_target: true,
	recon_target: true,
};
const AC: Record<number, AircraftConfig> = {};
for (const side of [BLUE, RED])
	AC[side] = {
		country: config.C.countries[side],
		escort: config.C.types.aircraft[side].escort,
		heli: config.C.types.aircraft[side].bda_heli,
	};
const OFFENSIVE: Partial<Record<string, boolean>> = {
	ground_strike: true,
	oca_strike: true,
	oca_sweep: true,
	recon: true,
};

function flags(base: string): Flags {
	if (S.base_kind[base] === "farp") return FARP_FLAGS;
	if (S.base_kind[base] === "airbase" || S.keysites[base]?.kind === "airbase")
		return AIRBASE_FLAGS;
	const configured = installations.flags_for_kind(S.keysites[base]?.kind ?? "");
	return configured === undefined
		? AIRBASE_FLAGS
		: {
				requires_cap: configured.requires_cap ?? false,
				requires_barcap: configured.requires_barcap ?? false,
				oca_target: configured.oca_target ?? false,
				ground_strike_target: configured.ground_strike_target ?? false,
				troop_insertion_target: configured.troop_insertion_target ?? false,
				recon_target: configured.recon_target ?? false,
			};
}
function nearestBase(side: Side, pos: WorldPoint): string | undefined {
	let best: string | undefined,
		distance = math.huge;
	for (const [name, owner] of Object.entries(S.base_owner)) {
		const base = S.base_pos[name];
		if (owner !== side || base === undefined) continue;
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
function nearestAny(pos: WorldPoint): string | undefined {
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
function efficiency(base: string): number {
	return (
		S.base_efficiency[base] ??
		S.base_health[base] ??
		S.keysites[base]?.health ??
		1
	);
}
function capRoute(
	base: Airbase,
	pos: Vec3,
	x: number,
	z: number,
): { points: WaypointData[] } {
	return {
		points: [
			{
				type: "TakeOffParkingHot",
				action: "From Parking Area Hot",
				airdromeId: base.getID(),
				alt: pos.y,
				alt_type: "BARO",
				speed: 0,
				ETA: 0,
				ETA_locked: true,
				x: pos.x,
				y: pos.z,
				name: "Depart",
				formation_template: "",
			},
			{
				type: "Turning Point",
				action: "Turning Point",
				alt: CAP_ALTITUDE_METRES,
				alt_type: "BARO",
				speed: CAP_SPEED_METRES_PER_SECOND,
				ETA: 0,
				ETA_locked: false,
				x,
				y: z,
				name: "CAP",
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
									maxDist: CAP_ENGAGEMENT_RANGE_METRES,
									priority: 0,
									targetTypes: ["Air"],
								},
							},
							{
								number: 2,
								auto: false,
								id: "Orbit",
								enabled: true,
								params: {
									pattern: "Race-Track",
									speed: CAP_SPEED_METRES_PER_SECOND,
									altitude: CAP_ALTITUDE_METRES,
									point: { x, y: z },
									point2: { x: x + CAP_ORBIT_LEG_METRES, y: z },
								},
							},
						],
					},
				},
			},
		],
	};
}
/**
 * CAP station time is up. This is a VIRTUAL RETIREMENT, not an RTB: no LAND event was seen and
 * no landing site was read, so it is settled through aircraft_lifecycle rather than here
 * (epic #17 P4). That module is the single owner of the reserve credit, the keysite launch slot
 * and the stand leases, which is what stops a CAP being credited twice if it ever does land.
 * Task-record cleanup stays here because reaction registered the task in the first place.
 *
 * The fallback branch is for a group aircraft_lifecycle holds no record of — an allocation that
 * was reversed before the spawn reached DCS, or a record from a previous generation. Nothing to
 * settle, but the slot and the airframe are still ours; exactly one of the two branches runs.
 */
function expireCap(group: Group, name: string, duration: number): void {
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		() => {
			if (_DMT_GEN !== generation) return undefined;
			if (
				!aircraft.retire_sortie(name, "CAP station time expired", "recycled")
			) {
				keysite.release_slot(name);
				if (group.isExist()) group.destroy();
			}
			cs.clear_task(name);
			return undefined;
		},
		undefined,
		timer.getTime() + duration,
	);
}
function spawnCap(
	side: Side,
	baseName: string,
	logFn: LogFn,
	duration = CAP_DURATION_SECONDS,
	orbit?: WorldPoint,
): boolean {
	if (!supply.consume_base(baseName, "escort", 1)) return false;
	const base = Airbase.getByName(baseName);
	if (base === undefined) {
		supply.recycle_base(baseName, "escort", 1);
		return false;
	}
	// From here the ALLOCATION owns the debit (epic #17 P4). reaction dispatches directly rather
	// than through task_board (reaction.c has no board pass), so it opens its own allocation; the
	// rollback contract is identical either way and nothing else may refund this debit.
	const allocation = aircraft.begin_allocation({
		task_type: orbit === undefined ? "cap" : "barcap",
		side,
		base: baseName,
		role: "escort",
		count: 1,
		log_fn: logFn,
	});
	const cfg = AC[side],
		pos = base.getPosition().p,
		id = cs.next_id(),
		prefix = orbit === undefined ? "CAP" : "BARCAP",
		name = string.format("%s-%d-%d", prefix, side, id);
	const group = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
		name,
		task: "CAP",
		hidden: false,
		airdromeId: base.getID(),
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
				},
			},
		],
		route: capRoute(base, pos, orbit?.x ?? pos.x, orbit?.z ?? pos.z),
	});
	aircraft.track(group);
	if (group === undefined) {
		aircraft.abort_allocation(allocation, "addGroup returned nothing");
		return false;
	}
	// reserve_slot is a no-op when the name already holds one, so record ownership only when
	// THIS call actually took the slot — the same rule task_board.try_assign applies.
	const slotOwned = S.group_launch_base[name] === undefined ? name : undefined;
	keysite.reserve_slot(baseName, name);
	cs.register_task(name, {
		task_type: orbit === undefined ? "cap" : "barcap",
		side,
		target_base: baseName,
		target_pos: S.base_pos[baseName],
		born_time: timer.getTime(),
	});
	aircraft.commit_allocation(allocation, name, slotOwned, name);
	expireCap(group, name, duration);
	logFn(
		string.format(
			"reaction %s #%d defending %s (dur=%ds)",
			prefix,
			id,
			baseName,
			duration,
		),
	);
	return true;
}
function reactOffense(
	base: string,
	objective: WorldPoint,
	attacker: WorldPoint,
	logFn: LogFn,
): void {
	const defender = S.base_owner[base];
	if (defender === undefined) return;
	const f = flags(base);
	if (f.requires_cap && !cs.has_task_against("cap", base, defender))
		spawnCap(defender, base, logFn);
	if (f.requires_barcap && !cs.has_task_against("barcap", base, defender)) {
		const dx = attacker.x - objective.x,
			dz = attacker.z - objective.z,
			length = Math.sqrt(dx * dx + dz * dz);
		if (length >= 1)
			spawnCap(defender, base, logFn, CAP_DURATION_SECONDS, {
				x: objective.x + (dx / length) * BARCAP_OFFSET_METRES,
				z: objective.z + (dz / length) * BARCAP_OFFSET_METRES,
			});
	}
}

// DCS adapter response window and jitter in seconds; EECH dispatches directly through its task system.
const UNDER_ATTACK_CAP_DURATION_SECONDS = 15 * 60;
const UNDER_ATTACK_RESPONSE_DELAY_SECONDS = 60;
const UNDER_ATTACK_RESPONSE_JITTER_SECONDS = 20;
export function on_keysite_under_attack(
	base: string | undefined,
	logFn: LogFn = () => undefined,
): void {
	if (base === undefined) return;
	const side = S.base_owner[base];
	if (side === undefined || !flags(base).requires_cap) return;
	const now = timer.getTime();
	if ((S.keysite_assist_timer[base] ?? 0) > now) return;
	const delay =
		UNDER_ATTACK_RESPONSE_DELAY_SECONDS +
		(math.random() * 2 - 1) * UNDER_ATTACK_RESPONSE_JITTER_SECONDS;
	S.keysite_assist_timer[base] = now + delay;
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		() => {
			if (
				_DMT_GEN === generation &&
				S.base_owner[base] === side &&
				!cs.has_task_against("cap", base, side)
			)
				spawnCap(side, base, logFn, UNDER_ATTACK_CAP_DURATION_SECONDS);
			return undefined;
		},
		undefined,
		now + delay,
	);
}

function createSeadRing(side: Side, pos: WorldPoint, logFn: LogFn): number {
	const cas = require<CasModule>("cas_bai_sead");
	let count = 0;
	for (const group of coalition.getGroups(cs.ENEMY[side]) ?? []) {
		if (count >= MAX_KEYSITE_SEAD_TASKS) break;
		if (!group.isExist()) continue;
		const unit = group.getUnit(1);
		if (unit === undefined || !unit.isExist()) continue;
		const a = unit.getDesc().attributes,
			aa =
				a?.["SAM"] ||
				a?.["AAA"] ||
				a?.["SR SAM"] ||
				a?.["MR SAM"] ||
				a?.["LR SAM"] ||
				a?.["IR Guided SAM"];
		if (!aa) continue;
		const p = unit.getPosition().p,
			dx = p.x - pos.x,
			dz = p.z - pos.z;
		const sector = nearestAny(p);
		if (
			dx * dx + dz * dz <= KEYSITE_SEAD_RANGE_METRES ** 2 &&
			sector !== undefined &&
			fow.get(sector, side) > KEYSITE_SEAD_FOW_THRESHOLD &&
			cas.spawn_sead_against(side, group, logFn, true)
		)
			count += 1;
	}
	return count;
}
function reactReconKeysite(
	side: Side,
	base: string | undefined,
	logFn: LogFn,
): void {
	if (base === undefined) return;
	const view = keysite.get(base);
	if (view === undefined || view.owner === side) return;
	const pos = view.pos,
		f = flags(base),
		eff = efficiency(base),
		basing = S.base_owner[base] !== undefined;
	if (
		pos !== undefined &&
		createSeadRing(side, pos, logFn) > KEYSITE_SEAD_SUPPRESSION_COUNT
	)
		return;
	if ((view.health ?? 1) <= cs.HEALTH_DESTROYED) return;
	const troop = require<TroopModule>("troop"),
		attacks = require<typeof import("./attack_waves")>("attack_waves"),
		cas = require<CasModule>("cas_bai_sead");
	if (
		f.troop_insertion_target &&
		eff < cs.MINIMUM_EFFICIENCY &&
		basing &&
		!cs.has_task_against("troop_insertion", base, side)
	) {
		troop.run_troop_insertion(side, logFn, base);
		const defender = S.base_owner[base];
		if (
			defender !== undefined &&
			defender !== side &&
			!cs.has_task_against("troop_insertion", base, defender)
		)
			troop.run_troop_insertion(defender, logFn, base);
	}
	if (f.oca_target) {
		if (!cs.has_task_against("oca_strike", base, side))
			attacks.run_oca_strike(side, logFn, base, true);
		if (!cs.has_task_against("oca_sweep", base, side))
			cas.run_oca_sweep(side, logFn, base, pos);
	}
	if (f.ground_strike_target && eff >= cs.MINIMUM_EFFICIENCY)
		attacks.run_strike(side, logFn, base, true);
}
function reactReconGroup(
	side: Side,
	objective: TaskInfo["objective"],
	logFn: LogFn,
): void {
	if (objective === undefined) return;
	const cas = require<CasModule>("cas_bai_sead");
	if (
		objective.kind === "aa_group" &&
		objective.group !== undefined &&
		objective.group.isExist()
	)
		cas.spawn_sead_against(side, objective.group, logFn, true);
	else if (objective.kind === "frontline_group" && objective.pos !== undefined)
		cas.spawn_bai_against(side, objective.pos, logFn, true);
}
function reactStrike(
	side: Side,
	base: string | undefined,
	pos: WorldPoint | undefined,
	logFn: LogFn,
): void {
	if (base === undefined || S.base_owner[base] === side) return;
	const eff = efficiency(base),
		attacks = require<typeof import("./attack_waves")>("attack_waves");
	if (eff >= cs.MINIMUM_EFFICIENCY) attacks.run_strike(side, logFn, base, true);
	else if (
		flags(base).recon_target &&
		pos !== undefined &&
		!cs.has_task_against("bda", base, side) &&
		!cs.has_task_against("recon", base, side)
	)
		spawn_bda(side, base, pos, logFn);
}

// DCS adapter dwell in seconds before BDA results are applied.
const BDA_LOITER_SECONDS = 3 * 60;
export function spawn_bda(
	side: Side,
	targetBase: string,
	target: WorldPoint,
	logFn: LogFn = () => undefined,
): void {
	const homeName = nearestBase(side, target);
	if (homeName === undefined || !supply.consume_base(homeName, "heli", 1))
		return;
	const home = Airbase.getByName(homeName);
	if (home === undefined) {
		supply.recycle_base(homeName, "heli", 1);
		return;
	}
	const cfg = AC[side],
		pos = home.getPosition().p,
		id = cs.next_id(),
		name = string.format("BDA-%d-%d", side, id);
	const departure: WaypointData = {
		type: "TakeOffParkingHot",
		action: "From Parking Area Hot",
		airdromeId: home.getID(),
		alt: pos.y,
		alt_type: "BARO",
		speed: 0,
		ETA: 0,
		ETA_locked: true,
		x: pos.x,
		y: pos.z,
		name: "Depart",
		formation_template: "",
	};
	const groupData: GroupData = {
		name,
		task: "Reconnaissance",
		hidden: false,
		airdromeId: home.getID(),
		units: [
			{
				name: `${name}-1`,
				type: cfg.heli,
				skill: "Good",
				x: pos.x,
				y: pos.z,
				alt: pos.y,
				alt_type: "BARO",
				speed: 0,
				heading: 0,
				payload: {
					fuel: BDA_FUEL_KILOGRAMS,
					flare: BDA_COUNTERMEASURE_COUNT,
					chaff: BDA_COUNTERMEASURE_COUNT,
					gun: PAYLOAD_GUN_PERCENT,
				},
			},
		],
		route: {
			points: [
				departure,
				{
					type: "Turning Point",
					action: "Fly Over Point",
					alt: BDA_ALTITUDE_METRES,
					alt_type: "BARO",
					speed: BDA_SPEED_METRES_PER_SECOND,
					ETA: 0,
					ETA_locked: false,
					x: target.x,
					y: target.z,
					name: "BDA",
					formation_template: "",
				},
			],
		},
	};
	// The ALLOCATION owns the "heli" debit from here (epic #17 P4), and it is opened BEFORE stand
	// selection so the parking lease it takes is owned too and comes back with the debit on any
	// rollback. reaction dispatches directly rather than through task_board, so it opens its own.
	const allocation = aircraft.begin_allocation({
		task_type: "bda",
		side,
		base: homeName,
		role: "heli",
		count: 1,
		log_fn: logFn,
	});
	// Stand selection can REFUSE (epic #17 P2): a helipad with real terminal data and no free
	// pad raises rather than stacking aircraft. spawn_bda runs straight off a reaction tick with
	// no pcall of its own, so an uncaught refusal here would kill that timer chain. Route it into
	// this function's existing spawn-failure path, which is now the allocation's own reversal —
	// so the "heli" consume_base debit above is unwound exactly once, by exactly one owner.
	const [seated, refusal] = pcall(() =>
		farpParking.configureDeparture(homeName, home, groupData, departure),
	);
	if (!seated) {
		logFn(
			string.format(
				"reaction: BDA %s not launched from %s — no parking stand (%s)",
				name,
				homeName,
				tostring(refusal),
			),
		);
		aircraft.abort_allocation(
			allocation,
			`no parking stand (${tostring(refusal)})`,
		);
		return;
	}
	const group = coalition.addGroup(
		cfg.country,
		Group.Category.HELICOPTER,
		groupData,
	);
	aircraft.track(group);
	if (group === undefined) {
		aircraft.abort_allocation(allocation, "addGroup returned nothing");
		return;
	}
	const slotOwned = S.group_launch_base[name] === undefined ? name : undefined;
	keysite.reserve_slot(homeName, name);
	cs.register_task(name, {
		task_type: "bda",
		side,
		target_base: targetBase,
		target_pos: target,
		objective: { kind: "keysite", base: targetBase },
		born_time: timer.getTime(),
	});
	aircraft.commit_allocation(allocation, name, slotOwned, name);
	const generation = _DMT_GEN;
	timer.scheduleFunction(
		() => {
			if (_DMT_GEN !== generation) return undefined;
			reactReconKeysite(side, targetBase, logFn);
			// VIRTUAL RETIREMENT, same shape as expireCap: the dwell timer, not the aircraft,
			// ends this sortie, so aircraft_lifecycle settles the credit / slot / stands once.
			if (!aircraft.retire_sortie(name, "BDA loiter complete", "recycled")) {
				keysite.release_slot(name);
				if (group.isExist()) group.destroy();
			}
			cs.clear_task(name);
			return undefined;
		},
		undefined,
		timer.getTime() + BDA_LOITER_SECONDS,
	);
}

// DCS adapter de-duplication window in seconds; the score/FOW split is reaction.c:735-780.
const COUNTER_BATTERY_TTL_SECONDS = 20 * 60;
export function on_artillery_fire(
	side: Side,
	battery: Group | undefined,
	pos: WorldPoint | undefined,
	logFn: LogFn = () => undefined,
): void {
	if (battery === undefined || pos === undefined) return;
	const name = battery.getName(),
		now = timer.getTime();
	for (const [key, expiry] of Object.entries(S.counter_battery))
		if (expiry <= now) delete S.counter_battery[key];
	if ((S.counter_battery[name] ?? 0) > now) return;
	const rating =
		1 -
		imap.get(side, imap.AIR_DEFENCE, pos) +
		imap.get(side, imap.SURFACE_DEFENCE, pos) +
		COUNTER_BATTERY_BASE_DISTANCE_WEIGHT *
			imap.get(side, imap.BASE_DISTANCE, pos);
	const sector = nearestAny(pos),
		visibility = sector === undefined ? 0 : fow.get(sector, side);
	S.counter_battery[name] = now + COUNTER_BATTERY_TTL_SECONDS;
	if (visibility > COUNTER_BATTERY_FOW_THRESHOLD)
		require<CasModule>("cas_bai_sead").spawn_bai_against(
			side,
			pos,
			logFn,
			false,
		);
	else
		require<typeof import("./recon")>("recon").spawn_recon(
			side,
			{ x: pos.x, y: pos.y ?? 0, z: pos.z },
			"CounterBty",
			logFn,
			{ kind: "frontline_group", pos, group: battery },
			true,
		);
	logFn(
		string.format(
			"%s counter-battery %s vs artillery (fow=%.2f rating=%.2f/4.0)",
			cs.SIDE_NAME[side],
			visibility > COUNTER_BATTERY_FOW_THRESHOLD ? "BAI" : "RECON",
			visibility,
			rating,
		),
	);
}

function pilotsCall(call: (pilots: Pilots) => void): void {
	const [ok, pilots] = pcall(() => require<Pilots>("pilots"));
	if (ok && pilots !== undefined) pcall(() => call(pilots));
}
function eventGroup(initiator?: DcsObject): Group | undefined {
	if (initiator?.getGroup === undefined) return undefined;
	const [ok, group] = pcall(() => initiator.getGroup?.());
	return ok ? group : undefined;
}
export function make_event_handler(
	logFn: LogFn = () => undefined,
): DcsEventHandler {
	return {
		onEvent(event: DcsEvent): void {
			const unit = event.initiator;
			if (event.id === world.event.S_EVENT_BIRTH) {
				pilotsCall((p) => p.on_birth(event));
				const group = eventGroup(unit);
				if (group === undefined || !group.isExist()) return;
				const task = cs.get_task(group.getName());
				if (
					unit !== undefined &&
					task?.target_base !== undefined &&
					OFFENSIVE[task.task_type]
				) {
					const objective = S.base_pos[task.target_base];
					if (objective !== undefined)
						reactOffense(
							task.target_base,
							objective,
							unit.getPosition().p,
							logFn,
						);
				}
			} else if (event.id === world.event.S_EVENT_LAND) {
				const group = eventGroup(unit);
				if (unit === undefined || group === undefined) return;
				const name = group.getName(),
					task = cs.get_task(name);
				// The MISSION result below is once-only per group and is cleared with the task.
				// AIRCRAFT-RESOURCE settlement is a separate concern with a different lifetime
				// (per airframe, and it outlives the task), so hand the lifecycle the facts it
				// needs to judge a recovery BEFORE cs.clear_task() drops them at the end of this
				// branch — whichever order DCS happens to dispatch the two handlers in.
				aircraft.note_task(name, task);
				if (task === undefined || S._completed[name]) return;
				S._completed[name] = true;
				if (
					task.task_type === "ground_strike" ||
					task.task_type === "oca_strike"
				)
					reactStrike(task.side, task.target_base, task.target_pos, logFn);
				else if (task.task_type === "recon") {
					if (
						task.objective?.kind !== undefined &&
						task.objective.kind !== "keysite"
					)
						reactReconGroup(task.side, task.objective, logFn);
					else reactReconKeysite(task.side, task.target_base, logFn);
				}
				const [result, rating] = cs.assess_task(task, "route_complete");
				cs.stat_task_result(task.side, result);
				const [playerOk, playerName] = pcall(() => unit.getPlayerName?.());
				if (playerOk && playerName !== undefined)
					pilotsCall((p) => p.on_debrief(unit, task, { result, rating }));
				cs.clear_task(name);
			} else if (event.id === world.event.S_EVENT_DEAD) {
				// An airframe THIS campaign retired after a completed recovery is not a combat
				// loss and must not terminate its task or score against the side. EECH makes the
				// same distinction in the aircraft destructor itself: hc_dstry.c:343-346 /
				// fw_dstry.c:332-335 return before any force-info or loss bookkeeping when the
				// entity is no longer INT_TYPE_ALIVE.
				const [retiredOk, retiredName] = pcall(() => unit?.getName());
				if (
					retiredOk &&
					retiredName !== undefined &&
					aircraft.is_retired_unit(retiredName)
				)
					return;
				pilotsCall((p) => p.on_death(event));
				const group = eventGroup(unit);
				if (group === undefined) return;
				const task = cs.get_task(group.getName());
				if (
					task !== undefined &&
					!(group.getUnits() ?? []).some((u) => u.isExist())
				) {
					const [result] = cs.assess_task(task, "terminated");
					cs.stat_task_result(task.side, result);
					cs.clear_task(group.getName());
				}
			} else if (event.id === world.event.S_EVENT_HIT)
				pilotsCall((p) => p.on_hit(event));
		},
	};
}
