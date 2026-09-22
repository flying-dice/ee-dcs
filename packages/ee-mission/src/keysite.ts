/** @noSelfInFile */
/*
-- keysite.lua
-- Inspired by:
--   aphavoc/source/entity/special/keysite/keysite.h     KEYSITE entity: side, strength, position
--   aphavoc/source/entity/special/keysite/ks_funcs.c    capture_keysite, destroy_keysite
--   aphavoc/source/entity/special/keysite/ks_updt.c     supply tracking, assign_timer (3 min)
--   aphavoc/source/entity/special/sector/sc_secfuncs.c  sector ownership, influence map updates
--   aphavoc/source/ai/highlevl/imaps.c                  IMAP_BASE_DISTANCE, IMAP_IMPORTANCE scoring
--
-- Manages airbase (keysite) ownership, structural health, damage, and capture.
-- Provides target-scoring used by attack_waves.lua.
-- Mirrors KEYSITE entity: sub_type=AIRBASE, side, keysite_strength, keysite_usable_state.
*/
import * as cs from "./campaign_state";
import type { KeysiteRecord, Side, WorldPoint } from "./campaign_types";
import * as imap from "./imap";
import * as installations from "./installations";
import { BLUE, NEUTRAL, RED } from "./sides";
import * as zones from "./zones";

type LogFunction = (this: void, message: string) => void;
export interface RateWeights {
	air_def: number;
	base_dist: number;
	eff: number;
	side_ratio: number;
	max: number;
}
export interface KeysiteView {
	name: string;
	kind?: string;
	side?: Side;
	owner?: Side;
	pos?: WorldPoint;
	health?: number;
	is_basing: boolean;
	rec?: KeysiteRecord;
}
export interface StrikeCandidate {
	name: string;
	pos: WorldPoint;
	eff: number;
	rating: number;
	recon_target: boolean;
	is_inst: boolean;
}
export interface StrikeDecision {
	action: "strike" | "recon";
	name: string;
	pos: WorldPoint;
	is_inst: boolean;
}
interface ObjectiveCandidate {
	name: string;
	isolation: number;
	rating: number;
}
interface ReactionModule {
	on_keysite_under_attack(baseName: string, logFn: LogFunction): void;
}
interface RegenModule {
	queue_reseed(
		side: Side,
		baseName: string,
		heliCount: number,
		fwCount: number,
		logFn: LogFunction,
	): void;
}
interface FrontlineModule {
	recompute(logFn?: LogFunction): void;
}
interface DefenceModule {
	regarrison(baseName: string, side: Side, logFn: LogFunction): void;
}
interface WinModule {
	check_win(logFn: LogFunction): void;
}
interface PersistModule {
	save(logFn: LogFunction): void;
}

const S = cs.S;
const SIDES: Side[] = [BLUE, RED];
const MIN_TASK_CREATION_RATIO = 0.75; // highlevl.c:88
const FOW_RECON_THRESHOLD = 0.25; // highlevl.c:1179
// DCS theatre-adapter safety floors: ignore authored/scoped subsets too small to
// sustain two forces. Their behavior is locked by the zone parity tests.
const MIN_SPLIT_ZONE_AIRFIELDS = 2;
const MIN_THEATRE_ZONE_AIRFIELDS = 4;
const MIN_CLUSTERED_AIRFIELDS = 6;
const THEATRE_CLUSTER_RADIUS_METRES = 130000; // ~128 EECH sectors × 2048 m / 2 (parser.c:347)
const METRES_PER_KILOMETRE = 1000;
const PERCENT_SCALE = 100;
const CAPTURE_MESSAGE_SECONDS = 20;

function allAirdromes(): Airbase[] {
	const result: Airbase[] = [];
	const seen: Record<string, boolean> = {};
	for (const side of [NEUTRAL, BLUE, RED]) {
		for (const airbase of coalition.getAirbases(side) ?? []) {
			const name = airbase.getName();
			// getDesc().category is the correct airbase-category surface; getCategory() is Object.BASE.
			const description = airbase.getDesc();
			if (description?.category === Airbase.Category.AIRDROME && !seen[name]) {
				seen[name] = true;
				result.push(airbase);
			}
		}
	}
	return result;
}

export function init_base_state(logFn: LogFunction = () => undefined): void {
	const assigned: Partial<Record<string, Side>> = {};
	for (const side of SIDES) {
		for (const airbase of coalition.getAirbases(side) ?? []) {
			if (airbase.getDesc()?.category === Airbase.Category.AIRDROME)
				assigned[airbase.getName()] = side;
		}
	}
	let all = allAirdromes();
	zones.load();

	// Fully authored theatre: keysite zones define every basing object and ownership.
	if (zones.has_keysite_zones()) {
		const keysiteZones = zones.keysites();
		let airbaseCount = 0;
		let farpCount = 0;
		let installationCount = 0;
		const farpSeen: Record<string, boolean> = {};
		for (const keysiteZone of keysiteZones) {
			if (keysiteZone.type !== "airbase" || keysiteZone.side === undefined)
				continue;
			let best: Airbase | undefined;
			let bestDistance = math.huge;
			for (const airbase of all) {
				const pos = airbase.getPosition().p;
				const distance = cs.dist2d(pos.x, pos.z, keysiteZone.x, keysiteZone.z);
				if (distance < bestDistance) {
					bestDistance = distance;
					best = airbase;
				}
			}
			if (best === undefined) continue;
			const name = best.getName();
			const pos = best.getPosition().p;
			S.base_pos[name] = { x: pos.x, z: pos.z };
			S.base_health[name] = 1;
			S.base_owner[name] = keysiteZone.side;
			S.base_kind[name] = "airbase";
			airbaseCount++;

			const [warehouseRead, inventory] = pcall(() =>
				best.getWarehouse().getInventory(),
			);
			if (warehouseRead && inventory?.aircraft !== undefined) {
				const summary: Record<string, number> = {};
				for (const [aircraftType, count] of pairs(inventory.aircraft))
					summary[aircraftType] = count;
				S.base_warehouse[name] = summary;
			}

			const assets = zones.statics_in_zone(keysiteZone.label);
			const scenery = zones
				.scenery_in_zone(keysiteZone.label, zones.RESOURCE_SCENERY)
				.map((row) => ({
					id: row.id,
					type: row.type,
					handle: row.handle,
					life0: row.life0,
					dead: false,
				}));
			const total = assets.length + scenery.length;
			if (total > 0) {
				S.keysites[`AB-${name}`] = {
					kind: "airbase",
					side: keysiteZone.side,
					pos: { x: pos.x, z: pos.z },
					home_base: name,
					assets,
					dead: {},
					scenery,
					total,
					alive: total,
					health: 1,
					flags: { ground_strike_target: true, recon_target: true },
					label: `Airfield assets ${name}`,
				};
			}
			logFn(
				string.format(
					"  airbase keysite %s → %s (%s) — warehouse %s, %d placed statics + %d scenery",
					name,
					cs.SIDE_NAME[keysiteZone.side] ?? "?",
					keysiteZone.label,
					S.base_warehouse[name] !== undefined ? "read" : "unavailable",
					assets.length,
					scenery.length,
				),
			);
		}

		for (const keysiteZone of keysiteZones) {
			if (keysiteZone.type === "farp" && keysiteZone.side !== undefined) {
				const stem = `FARP-${keysiteZone.label ?? "farp"}`;
				let unique = stem;
				let suffix = 1;
				while (S.base_owner[unique] !== undefined || farpSeen[unique]) {
					suffix++;
					unique = `${stem}-${suffix}`;
				}
				farpSeen[unique] = true;
				S.base_pos[unique] = { x: keysiteZone.x, z: keysiteZone.z };
				S.base_health[unique] = 1;
				S.base_owner[unique] = keysiteZone.side;
				S.base_kind[unique] = "farp";
				farpCount++;
				logFn(
					string.format(
						"  farp keysite %s → %s",
						unique,
						cs.SIDE_NAME[keysiteZone.side] ?? "?",
					),
				);
			} else if (keysiteZone.type !== "airbase") {
				installationCount++;
			}
		}
		logFn(
			string.format(
				"theatre from zones: %d airbases, %d FARPs, %d keysites",
				airbaseCount,
				farpCount,
				installationCount,
			),
		);
		cs.dbg(
			"keysite",
			"init_base_state (zone-authored theatre): %d airbases, %d FARPs, %d installations",
			airbaseCount,
			farpCount,
			installationCount,
		);
		designate_objectives(logFn);
		return;
	}

	const zoneOwner: Partial<Record<string, Side>> = {};
	let zoneScoped = false;
	if (zones.exists("BLUE") && zones.exists("RED")) {
		const scoped: Airbase[] = [];
		const total = all.length;
		for (const airbase of all) {
			const pos = airbase.getPosition().p;
			const side = zones.contains("BLUE", pos.x, pos.z)
				? BLUE
				: zones.contains("RED", pos.x, pos.z)
					? RED
					: undefined;
			if (side !== undefined) {
				scoped.push(airbase);
				zoneOwner[airbase.getName()] = side;
			}
		}
		if (scoped.length >= MIN_SPLIT_ZONE_AIRFIELDS) all = scoped;
		zoneScoped = true;
		logFn(
			string.format(
				"theatre from ME zones (BLUE/RED): %d of %d airfields in play",
				all.length,
				total,
			),
		);
	} else if (zones.exists("THEATRE")) {
		const scoped: Airbase[] = [];
		const total = all.length;
		for (const airbase of all) {
			const pos = airbase.getPosition().p;
			if (zones.contains("THEATRE", pos.x, pos.z)) scoped.push(airbase);
		}
		if (scoped.length >= MIN_THEATRE_ZONE_AIRFIELDS) all = scoped;
		zoneScoped = true;
		logFn(
			string.format(
				"theatre from ME zone (THEATRE): %d of %d airfields in play",
				all.length,
				total,
			),
		);
	}

	if (!zoneScoped) {
		const total = all.length;
		let bestCenter: Vec3 | undefined;
		let bestCount = -1;
		for (const candidate of all) {
			const center = candidate.getPosition().p;
			let count = 0;
			for (const airbase of all) {
				const pos = airbase.getPosition().p;
				if (
					cs.dist2d(pos.x, pos.z, center.x, center.z) <=
					THEATRE_CLUSTER_RADIUS_METRES
				)
					count++;
			}
			if (count > bestCount) {
				bestCount = count;
				bestCenter = center;
			}
		}
		if (bestCenter !== undefined) {
			const theatreCenter = bestCenter;
			const scoped = all.filter((airbase) => {
				const pos = airbase.getPosition().p;
				return (
					cs.dist2d(pos.x, pos.z, theatreCenter.x, theatreCenter.z) <=
					THEATRE_CLUSTER_RADIUS_METRES
				);
			});
			if (scoped.length >= MIN_CLUSTERED_AIRFIELDS) all = scoped;
		}
		logFn(
			string.format(
				"theatre scoped to ~%.0f km (densest cluster): %d of %d airfields in play",
				(THEATRE_CLUSTER_RADIUS_METRES * 2) / METRES_PER_KILOMETRE,
				all.length,
				total,
			),
		);
	}

	all.sort((left, right) => left.getPosition().p.x - right.getPosition().p.x);
	const half = math.floor(all.length / 2);
	const counts: Record<Side, number> = {
		[BLUE]: 0,
		[RED]: 0,
	};
	for (let index = 0; index < all.length; index++) {
		const airbase = all[index];
		const name = airbase.getName();
		const pos = airbase.getPosition().p;
		S.base_health[name] = 1;
		S.base_pos[name] = { x: pos.x, z: pos.z };
		const side =
			zoneOwner[name] ?? assigned[name] ?? (index < half ? BLUE : RED);
		S.base_owner[name] = side;
		counts[side]++;
		logFn(string.format("  keysite %s → %s", name, cs.SIDE_NAME[side] ?? "?"));
	}
	logFn(
		string.format(
			"keysites initialised: BLUE=%d RED=%d total=%d",
			counts[BLUE],
			counts[RED],
			all.length,
		),
	);
	cs.dbg(
		"keysite",
		"init_base_state (auto theatre): BLUE=%d RED=%d total=%d",
		counts[BLUE],
		counts[RED],
		all.length,
	);
	designate_objectives(logFn);
}

// setup.c:126-289 chooses five enemy objectives by normalized isolation plus frand1().
export function designate_objectives(
	logFn: LogFunction = () => undefined,
): void {
	S.objectives = {
		[BLUE]: [],
		[RED]: [],
	};
	for (const side of SIDES) {
		const enemy = cs.ENEMY[side];
		const candidates: ObjectiveCandidate[] = [];
		for (const [name, owner] of pairs(S.base_owner)) {
			const basePos = S.base_pos[name];
			if (owner !== enemy || basePos === undefined) continue;
			let isolation = math.huge;
			for (const [other, otherOwner] of pairs(S.base_owner)) {
				const otherPos = S.base_pos[other];
				if (otherOwner === enemy && other !== name && otherPos !== undefined) {
					isolation = math.min(
						isolation,
						cs.dist2d(basePos.x, basePos.z, otherPos.x, otherPos.z),
					);
				}
			}
			candidates.push({
				name,
				isolation: isolation === math.huge ? 0 : isolation,
				rating: 0,
			});
		}
		let maxIsolation = 0;
		for (const candidate of candidates)
			maxIsolation = math.max(maxIsolation, candidate.isolation);
		for (const candidate of candidates) {
			candidate.rating =
				(maxIsolation > 0 ? candidate.isolation / maxIsolation : 0) +
				math.random();
		}
		candidates.sort((left, right) => right.rating - left.rating);
		const count = math.min(candidates.length, cs.OBJECTIVES_PER_SIDE);
		const objectives = S.objectives[side] ?? [];
		for (let index = 0; index < count; index++)
			objectives.push(candidates[index].name);
		S.objectives[side] = objectives;
		logFn(
			string.format(
				"objectives %s (must capture %d enemy keysites): %s",
				cs.SIDE_NAME[side] ?? "?",
				count,
				table.concat(objectives, ", "),
			),
		);
		cs.dbg(
			"keysite",
			"objectives designated for %s: %d of %d enemy candidates -> %s",
			cs.SIDE_NAME[side] ?? "?",
			count,
			candidates.length,
			table.concat(objectives, ","),
		);
	}
}

// Landing-slot capacity proxies per-keysite route data (parser.c:2667). SMALL=assignment budget 3 +
// one headroom; LARGE doubles it. The port tracks one slot per sortie rather than per airframe.
export const SLOT_CAPACITY = { NONE: 0, SMALL: 4, LARGE: 8 };

export function base_slot_capacity(name?: string): number {
	const kind = name !== undefined ? S.base_kind[name] : undefined;
	return kind === "farp" || kind === "fob"
		? SLOT_CAPACITY.SMALL
		: SLOT_CAPACITY.LARGE;
}

export function slot_available(name?: string): number {
	if (name === undefined) return 0;
	return base_slot_capacity(name) - (S.base_inflight[name] ?? 0);
}

export function reserve_slot(base?: string, groupName?: string): void {
	if (
		base === undefined ||
		groupName === undefined ||
		S.group_launch_base[groupName] !== undefined
	)
		return;
	S.group_launch_base[groupName] = base;
	S.base_inflight[base] = (S.base_inflight[base] ?? 0) + 1;
}

export function release_slot(groupName?: string): void {
	if (groupName === undefined) return;
	const base = S.group_launch_base[groupName];
	if (base === undefined) return;
	delete S.group_launch_base[groupName];
	S.base_inflight[base] = math.max(0, (S.base_inflight[base] ?? 0) - 1);
}

export function get(name?: string): KeysiteView | undefined {
	if (name === undefined) return undefined;
	const basingOwner = S.base_owner[name];
	if (basingOwner !== undefined) {
		return {
			name,
			kind: S.base_kind[name],
			side: basingOwner,
			owner: basingOwner,
			pos: S.base_pos[name],
			health: S.base_health[name],
			is_basing: true,
		};
	}
	const record = S.keysites[name];
	if (record === undefined) return undefined;
	const owner =
		record.side ??
		(record.home_base !== undefined
			? S.base_owner[record.home_base]
			: undefined);
	return {
		name,
		kind: record.kind,
		side: owner,
		owner,
		pos: record.pos,
		health: record.health ?? 1,
		is_basing: false,
		rec: record,
	};
}

// Snapshot iterator matching the Lua module's closure-return API.
export function all(side?: Side): (this: void) => KeysiteView | undefined {
	const views: KeysiteView[] = [];
	for (const [name] of pairs(S.base_owner)) {
		const view = get(name);
		if (view !== undefined && (side === undefined || view.owner === side))
			views.push(view);
	}
	for (const [name] of pairs(S.keysites)) {
		const view = get(name);
		if (view !== undefined && (side === undefined || view.owner === side))
			views.push(view);
	}
	let index = 0;
	return () => {
		const view = views[index];
		index++;
		return view;
	};
}

export const RATE_GROUND_STRIKE: RateWeights = {
	air_def: 1,
	base_dist: 4,
	eff: 2,
	side_ratio: 2,
	max: 9,
}; // highlevl.c:1116-1127
export const RATE_OCA_STRIKE: RateWeights = {
	air_def: 1,
	base_dist: 4,
	eff: 0,
	side_ratio: 2,
	max: 7,
}; // highlevl.c:1373-1381

const SECTOR_RATIO_RADIUS = 200000;

function sectorRatio(pos: WorldPoint | undefined, side: Side): number {
	if (pos === undefined) return 0;
	const radiusSquared = SECTOR_RATIO_RADIUS * SECTOR_RATIO_RADIUS;
	let friendly = 0;
	let total = 0;
	for (const [name, owner] of pairs(S.base_owner)) {
		const basePos = S.base_pos[name];
		if (basePos !== undefined) {
			const dx = pos.x - basePos.x;
			const dz = pos.z - basePos.z;
			if (dx * dx + dz * dz <= radiusSquared) {
				total++;
				if (owner === side) friendly++;
			}
		}
	}
	return total === 0 ? 0 : friendly / total;
}

function nearestBaseTo(pos: WorldPoint): string | undefined {
	let best: string | undefined;
	let bestDistanceSquared = math.huge;
	for (const [name, basePos] of pairs(S.base_pos)) {
		const dx = pos.x - basePos.x;
		const dz = pos.z - basePos.z;
		const distanceSquared = dx * dx + dz * dz;
		if (distanceSquared < bestDistanceSquared) {
			bestDistanceSquared = distanceSquared;
			best = name;
		}
	}
	return best;
}

// highlevl.c:1116-1127 weighted IMAP formula. The commented-out importance term stays absent.
export function rate_pos(
	attacker: Side,
	targetPos: WorldPoint | undefined,
	targetEfficiency = 1,
	weights: RateWeights = RATE_GROUND_STRIKE,
): number {
	if (targetPos === undefined) return 0;
	const airDefence = imap.get(attacker, imap.AIR_DEFENCE, targetPos);
	const baseDistance = imap.get(attacker, imap.BASE_DISTANCE, targetPos);
	const ratio = sectorRatio(targetPos, attacker);
	return (
		weights.air_def * (1 - airDefence) +
		weights.base_dist * baseDistance +
		weights.eff * (1 - targetEfficiency) +
		weights.side_ratio * ratio
	);
}

export function rate_target(
	attacker: Side,
	targetName: string,
	weights: RateWeights = RATE_GROUND_STRIKE,
): number {
	const targetPos = S.base_pos[targetName];
	if (
		targetPos === undefined ||
		(S.base_health[targetName] ?? 1) <= cs.HEALTH_DESTROYED ||
		S.base_owner[targetName] === attacker
	)
		return 0;
	return rate_pos(attacker, targetPos, efficiency(targetName), weights);
}

export function pick_target(
	attacker: Side,
	logFn: LogFunction = () => undefined,
	weights: RateWeights = RATE_GROUND_STRIKE,
): LuaMultiReturn<[string | undefined, number]> {
	let bestName: string | undefined;
	let bestRating = -1;
	const enemy = cs.ENEMY[attacker];
	for (const [name, owner] of pairs(S.base_owner)) {
		if (
			owner === enemy ||
			(owner !== attacker && (S.base_health[name] ?? 1) < 1)
		) {
			const rating = rate_target(attacker, name, weights);
			if (rating > bestRating) {
				bestRating = rating;
				bestName = name;
			}
		}
	}
	if (bestName !== undefined) {
		logFn(
			string.format(
				"target: %s → %s (rating=%.2f health=%.0f%%)",
				cs.SIDE_NAME[attacker],
				bestName,
				bestRating,
				(S.base_health[bestName] ?? 1) * PERCENT_SCALE,
			),
		);
		cs.dbg(
			"keysite",
			"%s pick_target: %s rating=%.2f health=%.0f%%",
			cs.SIDE_NAME[attacker],
			bestName,
			bestRating,
			(S.base_health[bestName] ?? 1) * PERCENT_SCALE,
		);
	} else {
		cs.dbg(
			"keysite",
			"%s pick_target: no candidate found",
			cs.SIDE_NAME[attacker],
		);
	}
	return $multi(bestName, bestRating);
}

export function strike_candidates(
	attacker: Side,
	weights: RateWeights = RATE_GROUND_STRIKE,
): StrikeCandidate[] {
	const enemy = cs.ENEMY[attacker];
	const result: StrikeCandidate[] = [];
	for (const [name, owner] of pairs(S.base_owner)) {
		const health = S.base_health[name] ?? 1;
		const pos = S.base_pos[name];
		if (
			(owner === enemy || (owner !== attacker && health < 1)) &&
			pos !== undefined &&
			health > cs.HEALTH_DESTROYED
		) {
			const targetEfficiency = efficiency(name);
			result.push({
				name,
				pos,
				eff: targetEfficiency,
				rating: rate_pos(attacker, pos, targetEfficiency, weights),
				recon_target: true,
				is_inst: false,
			});
		}
	}
	for (const target of installations.strike_targets(attacker)) {
		result.push({
			name: target.name,
			pos: target.pos,
			eff: target.health,
			rating: rate_pos(attacker, target.pos, target.health, weights),
			recon_target: target.recon_target === true,
			is_inst: true,
		});
	}
	result.sort((left, right) => right.rating - left.rating);
	return result;
}

export function pick_targets(
	attacker: Side,
	count = 3,
	_logFn: LogFunction = () => undefined,
): StrikeDecision[] {
	const candidates = strike_candidates(attacker, RATE_GROUND_STRIKE);
	const decisions: StrikeDecision[] = [];
	if (candidates.length === 0 || candidates[0].rating <= 0) {
		cs.dbg("keysite", "%s strike funnel: 0 candidates", cs.SIDE_NAME[attacker]);
		return decisions;
	}
	const topRating = candidates[0].rating;
	const checked = math.min(candidates.length, count);
	let strikeCount = 0;
	let reconCount = 0;
	let ratioRejected = 0;
	let deduped = 0;
	let efficiencyGated = 0;
	for (let index = 0; index < checked; index++) {
		const candidate = candidates[index];
		if (candidate.rating / topRating < MIN_TASK_CREATION_RATIO) {
			ratioRejected++;
			continue;
		}
		const fowBase =
			S.base_pos[candidate.name] !== undefined
				? candidate.name
				: nearestBaseTo(candidate.pos);
		const fowValue =
			fowBase !== undefined
				? require<typeof import("./fog_of_war")>("fog_of_war").get(
						fowBase,
						attacker,
					)
				: 0;
		if (candidate.recon_target || fowValue < FOW_RECON_THRESHOLD) {
			if (
				cs.has_task_against("recon", candidate.name, attacker) ||
				cs.has_task_against("bda", candidate.name, attacker) ||
				cs.has_task_against("ground_strike", candidate.name, attacker) ||
				cs.has_task_against("troop_insertion", candidate.name, attacker)
			) {
				deduped++;
			} else {
				decisions.push({
					action: "recon",
					name: candidate.name,
					pos: candidate.pos,
					is_inst: candidate.is_inst,
				});
				reconCount++;
			}
		} else if (candidate.eff < cs.MINIMUM_EFFICIENCY) {
			efficiencyGated++;
		} else if (
			cs.has_task_against("ground_strike", candidate.name, attacker) ||
			cs.has_task_against("troop_insertion", candidate.name, attacker)
		) {
			deduped++;
		} else {
			decisions.push({
				action: "strike",
				name: candidate.name,
				pos: candidate.pos,
				is_inst: candidate.is_inst,
			});
			strikeCount++;
		}
	}
	cs.dbg(
		"keysite",
		"%s strike funnel: %d cands -> top %d checked: %d strike, %d recon(fogged/recon_target), %d below-ratio, %d deduped, %d eff-gated",
		cs.SIDE_NAME[attacker],
		candidates.length,
		checked,
		strikeCount,
		reconCount,
		ratioRejected,
		deduped,
		efficiencyGated,
	);
	return decisions;
}

export function strike_damage(
	baseName: string,
	damage: number,
	logFn: LogFunction = () => undefined,
): number | undefined {
	const oldHealth = S.base_health[baseName];
	if (oldHealth === undefined) return undefined;
	const newHealth = math.max(0, oldHealth - damage);
	S.base_health[baseName] = newHealth;
	S.base_efficiency[baseName] = newHealth;
	S.base_last_strike[baseName] = timer.getTime();
	const newlyNeutralised =
		oldHealth >= cs.HEALTH_NEUTRALISED && newHealth < cs.HEALTH_NEUTRALISED;
	logFn(
		string.format(
			"keysite strike: %s (%s) %.0f%%→%.0f%%%s",
			baseName,
			cs.SIDE_NAME[S.base_owner[baseName]] ?? "?",
			oldHealth * PERCENT_SCALE,
			newHealth * PERCENT_SCALE,
			newlyNeutralised
				? string.format(
						" — NEUTRALISED, capturable (<%.0f%%)",
						cs.MINIMUM_EFFICIENCY * PERCENT_SCALE,
					)
				: "",
		),
	);
	cs.dbg(
		"keysite",
		"strike_damage: %s %.0f%%->%.0f%% (dmg=%.2f)%s",
		baseName,
		oldHealth * PERCENT_SCALE,
		newHealth * PERCENT_SCALE,
		damage,
		newlyNeutralised ? " -> NEUTRALISED" : "",
	);
	const [loaded, reaction] = pcall(() => require<ReactionModule>("reaction"));
	if (loaded && reaction !== undefined)
		pcall(() => reaction.on_keysite_under_attack(baseName, logFn));
	return newHealth;
}

export function efficiency(baseName: string): number {
	return S.base_efficiency[baseName] ?? S.base_health[baseName] ?? 1;
}

const CAPTURE_RANGE = 5000;
const CAPTURE_REPAIR_LARGE = 0.4; // ~5 of ~12 airbase buildings
const CAPTURE_REPAIR_SMALL = 1.0; // five buildings effectively covers a FARP/FOB
const CAPTURE_REGEN_HELI = 6; // keysite.c:1490
const CAPTURE_REGEN_FW = 4; // keysite.c:1494

// mb_msgs.c:2287-2308 defence score and probabilistic capture test.
export function capture_roll(
	baseName: string,
	memberCount = 1,
	losses = 0,
): boolean {
	const targetEfficiency = efficiency(baseName);
	const minimum = cs.MINIMUM_EFFICIENCY;
	let defence = (targetEfficiency - minimum) / (1 - minimum);
	defence *= memberCount / (memberCount + losses);
	const roll = math.random();
	const captured = defence < roll;
	cs.dbg(
		"capture",
		"capture_roll %s: eff=%.2f defence_score=%.2f roll=%.2f -> %s",
		baseName,
		targetEfficiency,
		defence,
		roll,
		captured ? "CAPTURED" : "REPELLED",
	);
	return captured;
}

function reseedRegenOnCapture(
	oldSide: Side,
	newSide: Side,
	baseName: string,
	logFn: LogFunction,
): void {
	const supply = require<typeof import("./supply")>("supply");
	supply.recycle_side(newSide, "heli", CAPTURE_REGEN_HELI);
	supply.recycle_side(newSide, "striker", CAPTURE_REGEN_FW);
	const shrink = (
		side: Side,
		role: "heli" | "striker",
		requested: number,
	): void => {
		const available = supply.reserve_side(side, role);
		for (let index = 0; index < math.min(available, requested); index++) {
			if (!supply.consume_side(side, role, 1)) break;
		}
	};
	shrink(oldSide, "heli", CAPTURE_REGEN_HELI);
	shrink(oldSide, "striker", CAPTURE_REGEN_FW);

	const [loaded, regen] = pcall(() => require<RegenModule>("regen"));
	if (loaded && regen !== undefined) {
		regen.queue_reseed(
			newSide,
			baseName,
			CAPTURE_REGEN_HELI,
			S.base_kind[baseName] === "airbase" ? CAPTURE_REGEN_FW : 0,
			logFn,
		);
	}
}

export function do_capture(
	baseName: string,
	newSide: Side,
	logFn: LogFunction = () => undefined,
): boolean {
	const oldSide = S.base_owner[baseName];
	if (oldSide === newSide) {
		cs.dbg(
			"capture",
			"do_capture NO-OP: %s already owned by %s",
			baseName,
			cs.SIDE_NAME[newSide],
		);
		return false;
	}
	S.base_owner[baseName] = newSide;
	const repair =
		S.base_kind[baseName] === "airbase"
			? CAPTURE_REPAIR_LARGE
			: CAPTURE_REPAIR_SMALL;
	S.base_health[baseName] = math.min(
		1,
		(S.base_health[baseName] ?? 0) + repair,
	);
	S.base_efficiency[baseName] = S.base_health[baseName];

	let capturedAircraft = 0;
	const ledger = S.base_ledger[baseName];
	if (ledger !== undefined) {
		for (const [, count] of pairs(ledger)) capturedAircraft += count ?? 0;
	}
	cs.dbg(
		"capture",
		"%s captures %d parked aircraft with %s (ledger kept under new owner; keysite.c:1375-1393, command_line_capture_aircraft=TRUE)",
		cs.SIDE_NAME[newSide],
		capturedAircraft,
		baseName,
	);

	let terminated = 0;
	const doomed: string[] = [];
	for (const [groupName, task] of pairs(S.active_tasks)) {
		if (task.target_base === baseName) doomed.push(groupName);
	}
	for (const groupName of doomed) {
		cs.clear_task(groupName);
		terminated++;
	}
	for (const task of S.board_tasks) {
		if (task.state === "UNASSIGNED" && task.target.base === baseName) {
			task.state = "FAILED";
			terminated++;
		}
	}
	if (terminated > 0) {
		cs.dbg(
			"capture",
			"%s task-termination on capture of %s: %d task(s) cleared (keysite.c:1229-1260)",
			cs.SIDE_NAME[newSide],
			baseName,
			terminated,
		);
	}

	reseedRegenOnCapture(oldSide, newSide, baseName, logFn);
	cs.recalc_strength();
	logFn(
		string.format(
			"CAPTURE: %s seizes %s from %s (health→%.0f%%, +%d heli/+%d fw reseed)",
			cs.SIDE_NAME[newSide] ?? "?",
			baseName,
			cs.SIDE_NAME[oldSide] ?? "NEUTRAL",
			(S.base_health[baseName] ?? 0) * PERCENT_SCALE,
			CAPTURE_REGEN_HELI,
			CAPTURE_REGEN_FW,
		),
	);
	cs.dbg(
		"capture",
		"OWNER TRANSITION: %s %s -> %s (health->%.0f%%, kind=%s)",
		baseName,
		cs.SIDE_NAME[oldSide] ?? "NEUTRAL",
		cs.SIDE_NAME[newSide] ?? "?",
		(S.base_health[baseName] ?? 0) * PERCENT_SCALE,
		S.base_kind[baseName],
	);
	trigger.action.outText(
		string.format("%s captured by %s!", baseName, cs.SIDE_NAME[newSide]),
		CAPTURE_MESSAGE_SECONDS,
	);

	const [frontlineLoaded, frontline] = pcall(() =>
		require<FrontlineModule>("frontline"),
	);
	if (frontlineLoaded && frontline !== undefined)
		pcall(() => frontline.recompute(logFn));
	const [defenceLoaded, defence] = pcall(() =>
		require<DefenceModule>("base_defenses"),
	);
	if (defenceLoaded && defence !== undefined)
		pcall(() => defence.regarrison(baseName, newSide, logFn));
	const [winLoaded, win] = pcall(() => require<WinModule>("win_condition"));
	if (winLoaded && win !== undefined) pcall(() => win.check_win(logFn));
	const [persistLoaded, persist] = pcall(() =>
		require<PersistModule>("persist"),
	);
	if (persistLoaded && persist !== undefined) pcall(() => persist.save(logFn));
	return true;
}

export function try_capture(logFn: LogFunction = () => undefined): void {
	let belowMinimum = 0;
	let attempts = 0;
	for (const [baseName, owner] of pairs(S.base_owner)) {
		if (efficiency(baseName) >= cs.MINIMUM_EFFICIENCY) continue;
		belowMinimum++;
		const basePos = S.base_pos[baseName];
		if (basePos === undefined) continue;
		for (const [side, groups] of pairs(S.ground_groups)) {
			if (side === owner || (side !== BLUE && side !== RED)) continue;
			for (const [, record] of pairs(groups)) {
				const column = record.grp;
				if (!cs.group_is_alive(column)) continue;
				const units = column.getUnits();
				const lead = units?.[0];
				if (units === undefined || lead === undefined || !lead.isExist())
					continue;
				const unitPos = lead.getPosition().p;
				if (
					cs.dist2d(unitPos.x, unitPos.z, basePos.x, basePos.z) < CAPTURE_RANGE
				) {
					attempts++;
					if (capture_roll(baseName, units.length, 0))
						do_capture(baseName, side, logFn);
					else
						logFn(
							string.format("capture repelled at %s (defence held)", baseName),
						);
					break;
				}
			}
		}
	}
	if (belowMinimum > 0) {
		cs.dbg(
			"capture",
			"try_capture tick: %d bases below min-efficiency, %d ground-column capture attempts",
			belowMinimum,
			attempts,
		);
	}
}
