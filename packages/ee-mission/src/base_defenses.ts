/** @noSelfInFile */
/*
-- base_defenses.lua
-- EECH source: aphavoc/source/gunships/campaign/populate/popread.c
--   read_population_sam_placements (popread.c:2148-2212): for EVERY population AAA/SAM placement point
--   the engine spawns an ENTITY_SUB_TYPE_GROUP_ANTI_AIRCRAFT group, formation
--   FORMATION_COMPONENT_LIGHT_SAM_AAA_GROUP (popread.c:2204), member count = max(0, component_count-1)
--   = 2 (popread.c:2208), side = the initial sector side. The placement POINTS come from the map
--   population templates (TEMPLATE_TYPE_AIRFIELD / TEMPLATE_TYPE_AAASAM, popread.c:100-101), which seed
--   SEVERAL such points around every airfield/town → EECH keysites, especially airbases, are ringed by
--   many AA groups.
--
-- This module ports that: each basing keysite (and each installation keysite) is ringed with N
-- LIGHT_SAM_AAA_GROUP groups. Because the per-keysite point DENSITY lives in the map population data
-- (not the C tree), N is a DOCUMENTED DESIGNER PROXY (config.defenses.groups_per: airbase=3, farp=1,
-- installation=1; author sets 0 to opt a class out). The per-group composition is FORMCOMP.DAT:535-545
-- LIGHT_SAM_AAA_GROUP's first TWO slots (popread.c:2208 count-1=2): BLUE {M48 Chaparral, Vulcan},
-- RED {2S6 Tunguska (SA-19), Strela-10M3 (SA-13)}. FORMCOMP HEAVY_SAM_AAA_GROUP:516-530 has no code
-- consumer in the shipped tree (popread.c:2204 uses LIGHT only) → deliberately NOT ported.
--
-- CLASSIFICATION (critical): these groups are SITE AA (EECH air_attack_strength==10 non-frontline AA,
-- highlevl.c:1981) → SEAD targets, NOT campaign ground groups. Their name prefix "AD-" does NOT match
-- the protected campaign-group tag set (^GndCol / ^Arty / -def$ / ^Patrol), so cas_bai_sead's
-- group_frontline_flag returns nil → get_enemy_aa_targets picks them up and get_enemy_ground_targets
-- excludes them (their lead unit has a SAM/AAA attribute). imap.update_air_defence scans AA by unit
-- attribute with no name filter, so they feed the AIR_DEFENCE layer automatically.
--
-- ECONOMY: FREE OOB placement — no force_reserve consume. EECH population AA is engine-placed at map
-- load and never draws on force_info hardware (popread.c:2148-2212); the old garrison here also spawned
-- free. They are NOT registered as keysite assets (register_static_death untouched) — they defend;
-- keysite health stays building-driven.
--
-- Spawned through coalition.addGroup → intercepted by spawn_queue, so the rings drain in over time.
-- reset.nuke clears them; they re-seed on the next injection (S.base_ad_groups is cleared at init).
--
-- POPULATION FIRING POINTS (added): popread.c:1389-1439 (read_population_sam_placements' building
-- scene-link branch) additionally spawns SINGLE-UNIT GROUP_STATIC_INFANTRY groups at each population
-- building link — LIGHT/MEDIUM/HEAVY_FIRING_POINT MG posts (FORMCOMP.DAT:693-717 :COUNT 1) and
-- INFANTRY_SAM_STANDING/KNEELING MANPAD soldiers (FORMCOMP.DAT:617-631 :COUNT 1), linked to the closest
-- keysite, sector-side owned. This module scatters an even MG/MANPAD mix inside each keysite's footprint
-- (config.defenses.firing_points count = designer proxy for the map population density). CLASSIFICATION:
-- GROUP_STATIC_INFANTRY frontline_flag = NONE (gp_dbase.c:887) and air_attack_strength = 6 (:896) → the
-- "FP-" name maps to group_frontline_flag 0: a target of NEITHER CAS(==1) nor BAI(>1), and excluded from
-- the generator SEAD's get_enemy_aa_targets (highlevl.c:1981 wants air_attack==10 site AA). MANPADs still
-- feed the AIR_DEFENCE imap by attribute (desired). Tracked in S.base_fp_groups; re-manned on capture.
*/
import * as config from "./config";
import * as cs from "./campaign_state";
import * as installations from "./installations";
import * as zones from "./zones";
import type { WorldPoint } from "./campaign_types";

type LogFunction = (this: void, message: string) => void;

const S = cs.S;
const DEF = config.C.defenses;
const GROUP_UNITS: Record<number, string[]> = {};
const MG_TYPE: Record<number, string> = {};
const MANPAD_TYPE: Record<number, string> = {};

for (const side of [coalition.side.BLUE, coalition.side.RED]) {
	GROUP_UNITS[side] = DEF.group[side];
	MG_TYPE[side] = DEF.mg[side];
	MANPAD_TYPE[side] = DEF.manpad[side];
}

function groupsForKind(kind: string): number {
	if (kind === "airbase") return DEF.groups_per.airbase ?? 0;
	if (kind === "farp") return DEF.groups_per.farp ?? 0;
	return DEF.groups_per.installation ?? 0;
}

function firingPointsForKind(kind: string): number {
	if (kind === "airbase") return DEF.firing_points.airbase ?? 0;
	if (kind === "farp") return DEF.firing_points.farp ?? 0;
	return DEF.firing_points.installation ?? 0;
}

function spawnRing(
	key: string,
	tag: string,
	side: number,
	pos: WorldPoint | undefined,
	count: number,
	_logFn: LogFunction,
): number {
	if (count <= 0) return 0;
	const prototype = GROUP_UNITS[side];
	const country = config.C.countries[side];
	if (
		prototype === undefined ||
		prototype.length === 0 ||
		country === undefined ||
		pos === undefined
	) {
		cs.dbg(
			"basedef",
			"spawn_ring ABORT %s: proto=%s country=%s pos=%s",
			tag,
			tostring(prototype !== undefined),
			tostring(country !== undefined),
			tostring(pos !== undefined),
		);
		return 0;
	}
	S.base_ad_groups ??= {};
	const recorded: string[] = S.base_ad_groups[key] ?? [];
	let placed = 0;
	for (let index = 0; index < count; index++) {
		const angle = index * ((2 * math.pi) / count);
		const spawnPos = cs.snap_land(
			pos.x + math.cos(angle) * DEF.ring_radius,
			pos.z + math.sin(angle) * DEF.ring_radius,
			pos.x,
			pos.z,
		);
		const groupName = string.format("AD-%s-%d", tag, cs.next_id());
		const units: UnitData[] = [];
		for (let unitIndex = 0; unitIndex < prototype.length; unitIndex++) {
			units.push({
				name: `${groupName}-${unitIndex + 1}`,
				type: prototype[unitIndex],
				skill: "Average",
				x: spawnPos.x + unitIndex * 30,
				y: spawnPos.z,
				heading: 0,
			});
		}
		const [ok] = pcall(() =>
			coalition.addGroup(country, Group.Category.GROUND, {
				name: groupName,
				task: "Ground Nothing",
				units,
				route: {
					points: [
						{
							x: spawnPos.x,
							y: spawnPos.z,
							type: "Turning Point",
							action: "Off Road",
							speed: 0,
							ETA: 0,
							ETA_locked: true,
						},
					],
				},
			}),
		);
		if (ok) {
			placed++;
			recorded.push(groupName);
		}
	}
	S.base_ad_groups[key] = recorded;
	return placed;
}

// popread.c:1389-1439 also spawns one GROUP_STATIC_INFANTRY group per population building link:
// firing-point MG posts (FORMCOMP.DAT:693-717) and MANPAD soldiers (FORMCOMP.DAT:617-631).
function spawnFiringPoints(
	key: string,
	tag: string,
	side: number,
	pos: WorldPoint | undefined,
	count: number,
	_logFn: LogFunction,
): number {
	if (count <= 0) return 0;
	const country = config.C.countries[side];
	const machineGun = MG_TYPE[side];
	const manpad = MANPAD_TYPE[side];
	if (
		country === undefined ||
		pos === undefined ||
		machineGun === undefined ||
		manpad === undefined
	) {
		cs.dbg(
			"basedef",
			"spawn_firing_points ABORT %s: country=%s pos=%s mg=%s manpad=%s",
			tag,
			tostring(country !== undefined),
			tostring(pos !== undefined),
			tostring(machineGun !== undefined),
			tostring(manpad !== undefined),
		);
		return 0;
	}
	S.base_fp_groups ??= {};
	const recorded: string[] = S.base_fp_groups[key] ?? [];
	let placed = 0;
	for (let index = 0; index < count; index++) {
		const unitType = index % 2 === 0 ? machineGun : manpad;
		const angle = math.random() * 2 * math.pi;
		const radius = math.random() * DEF.ring_radius;
		const spawnPos = cs.snap_land(
			pos.x + math.cos(angle) * radius,
			pos.z + math.sin(angle) * radius,
			pos.x,
			pos.z,
		);
		const altitude = land.getHeight({ x: spawnPos.x, y: spawnPos.z });
		const groupName = string.format("FP-%s-%d", tag, cs.next_id());
		const [ok] = pcall(() =>
			coalition.addGroup(country, Group.Category.GROUND, {
				name: groupName,
				task: "Ground Nothing",
				units: [
					{
						name: `${groupName}-1`,
						type: unitType,
						skill: "Average",
						x: spawnPos.x,
						y: spawnPos.z,
						alt: altitude,
						alt_type: "BARO",
						heading: 0,
					},
				],
				route: {
					points: [
						{
							x: spawnPos.x,
							y: spawnPos.z,
							type: "Turning Point",
							action: "Off Road",
							speed: 0,
							ETA: 0,
							ETA_locked: true,
						},
					],
				},
			}),
		);
		if (ok) {
			placed++;
			recorded.push(groupName);
		}
	}
	S.base_fp_groups[key] = recorded;
	return placed;
}

export function init(logFn: LogFunction = () => undefined): void {
	S.base_ad_groups = {};
	S.base_fp_groups = {};
	const zoned = zones.has_keysite_zones();
	let groupCount = 0;
	let siteCount = 0;
	let firingPointCount = 0;

	for (const [baseName, side] of pairs(S.base_owner)) {
		if (side === coalition.side.BLUE || side === coalition.side.RED) {
			const kind = S.base_kind?.[baseName] ?? "airbase";
			const pos = S.base_pos[baseName];
			const tag = string.sub(baseName, 1, 10);
			const placed = spawnRing(
				baseName,
				tag,
				side,
				pos,
				groupsForKind(kind),
				logFn,
			);
			firingPointCount += spawnFiringPoints(
				baseName,
				tag,
				side,
				pos,
				firingPointsForKind(kind),
				logFn,
			);
			groupCount += placed;
			if (placed > 0) siteCount++;
		}
	}

	for (const [keysiteName, record] of pairs(S.keysites ?? {})) {
		if (
			record.kind !== "airbase" &&
			record.pos !== undefined &&
			!record.templated
		) {
			const side =
				record.side ??
				installations.side_of(record) ??
				(record.home_base !== undefined
					? S.base_owner[record.home_base]
					: undefined);
			if (side === coalition.side.BLUE || side === coalition.side.RED) {
				const tag = string.sub(keysiteName, 1, 12);
				const placed = spawnRing(
					keysiteName,
					tag,
					side,
					record.pos,
					groupsForKind("installation"),
					logFn,
				);
				firingPointCount += spawnFiringPoints(
					keysiteName,
					tag,
					side,
					record.pos,
					firingPointsForKind("installation"),
					logFn,
				);
				groupCount += placed;
				if (placed > 0) siteCount++;
			}
		}
	}

	logFn(
		string.format(
			"base_defenses: air-defence rings seeded — %d LIGHT_SAM_AAA groups + %d firing-point/MANPAD groups across %d keysites%s",
			groupCount,
			firingPointCount,
			siteCount,
			zoned ? " (zone-authored theatre)" : " (auto theatre)",
		),
	);
	cs.dbg(
		"basedef",
		"init: %d AD groups + %d firing-point groups across %d keysites (zoned=%s)",
		groupCount,
		firingPointCount,
		siteCount,
		tostring(zoned),
	);
}

// Capture re-garrisoning first tears down surviving old-owner groups, then seeds the new owner's
// ring. This mirrors population units changing with sector ownership.
export function regarrison(
	baseName: string,
	newSide: number,
	logFn: LogFunction = () => undefined,
): void {
	S.base_ad_groups ??= {};
	S.base_fp_groups ??= {};
	let tornDown = 0;
	let firingPointsTornDown = 0;
	for (const groupName of S.base_ad_groups[baseName] ?? []) {
		const group = Group.getByName(groupName);
		if (group !== undefined) {
			pcall(() => group.destroy());
			tornDown++;
		}
	}
	delete S.base_ad_groups[baseName];
	for (const groupName of S.base_fp_groups[baseName] ?? []) {
		const group = Group.getByName(groupName);
		if (group !== undefined) {
			pcall(() => group.destroy());
			firingPointsTornDown++;
		}
	}
	delete S.base_fp_groups[baseName];
	const kind = S.base_kind?.[baseName] ?? "airbase";
	const pos = S.base_pos[baseName];
	const tag = string.sub(baseName, 1, 10);
	const placed = spawnRing(
		baseName,
		tag,
		newSide,
		pos,
		groupsForKind(kind),
		logFn,
	);
	const firingPoints = spawnFiringPoints(
		baseName,
		tag,
		newSide,
		pos,
		firingPointsForKind(kind),
		logFn,
	);
	logFn(
		string.format(
			"base_defenses: re-garrisoned %s for %s (%d AD + %d firing-point groups, %d+%d old torn down)",
			baseName,
			cs.SIDE_NAME[newSide] ?? "?",
			placed,
			firingPoints,
			tornDown,
			firingPointsTornDown,
		),
	);
	cs.dbg(
		"basedef",
		"regarrison %s -> %s: %d AD + %d FP groups placed, %d+%d survivors torn down",
		baseName,
		cs.SIDE_NAME[newSide] ?? "?",
		placed,
		firingPoints,
		tornDown,
		firingPointsTornDown,
	);
}
