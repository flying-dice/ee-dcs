/** @noSelfInFile */
/*
-- config.lua — SCENARIO-DATA configuration loader (the port's "warzone data file").
--
-- WHAT THIS IS (and is NOT):
--   EECH itself splits its campaign into two layers: hard ENGINE CONSTANTS compiled into the C source
--   (cadences, formulas, thresholds — highlevl.c / reaction.c / ks_dbase.c / force.c) and DATA files
--   loaded from disk (FORMCOMP.DAT formation compositions, the WUT warzone-unit tables, faction rosters).
--   This module is the port's equivalent of that DATA layer: the SCENARIO warzone data a mission author
--   may legitimately re-skin — unit type names, countries, weapon payloads, reserve counts, installation
--   statics, and a handful of documented designer/proxy theatre knobs.
--
--   EECH-CITED ENGINE CONSTANTS ARE DELIBERATELY **NOT** HERE (CLAUDE.md prime directive). Cadences,
--   strike/repair/capture formulas, MINIMUM_EFFICIENCY, ESCORT thresholds, FOW gates, damage fractions,
--   ETA-gate speeds, CRUISE_SPEED and all spawn kinematics (alt/speed/fuel) stay hardcoded in their
--   modules with their file:line citations. If a value traces to the EECH C source it is not tunable.
--
-- HOW AN AUTHOR OVERRIDES IT:
--   Set a global table `_G.DMT_CONFIG` BEFORE the campaign script runs (a MISSION START → DO SCRIPT
--   trigger, or a dofile before injection). It is deep-merged OVER the DEFAULTS below (user wins per
--   LEAF key; ARRAYS — slot lists, pylon lists, unit lists — replace wholesale, never merge per-index).
--   The merged result is exposed as `config.C` and also on `_G.DMT_ACTIVE_CONFIG` for inspection.
--
--   SIDE-KEYED tables use the STRING keys "blue" / "red" in DMT_CONFIG (NOT coalition.side numbers —
--   those collide with array indices and would break the deep-merge). `config.C` re-keys them to
--   coalition.side.BLUE / coalition.side.RED for the consuming modules. See README "Configuring the
--   campaign (DMT_CONFIG)".
--
-- BOOT VALIDATION:
--   main.lua calls `config.load_and_validate(log_fn)` AFTER reset.nuke but BEFORE game_loop starts (so
--   before ANY spawn). It DB-checks every aircraft/ground unit type (Unit.getDescByName), structurally
--   checks statics/payloads (they cannot be verified from the mission env), and falls each bad USER
--   override back to its DEFAULT (resilient boot). A DEFAULT that itself fails the DB check (e.g. the
--   AH-64D module is not installed — a real past incident) raises a LOUD warning + on-screen outText
--   naming the missing types and the fix. Boot continues either way; spawn-path pcall+refund keeps the
--   economy safe on any residual failure.
--
-- Hoisted from (defaults trace back to these literals, citations preserved):
--   attack_waves.lua / cas_bai_sead.lua / reaction.lua / recon.lua / regen.lua / heli_war.lua (aircraft
--   + pylon tables), troop.lua (transport heli + infantry), ground_forces.lua (FORMCOMP.DAT slot rows),
--   installations.lua (KINDS/PALETTE/garrison/EWR/AAA/SAM), base_defenses.lua (AD-ring composition,
--   counts, radius → the `defenses` section),
--   farps.lua (FARP static + fixed-wing count + front distance), supply.lua (reserve allotments),
--   payloads.lua (the pylon/CLSID tables — this module exposes them).
*/
import * as cs from "./campaign_state";
import type { InventoryLedger, Side } from "./campaign_types";
import * as payloads from "./payloads";

export interface AircraftRoster {
	striker: string;
	escort: string;
	recon: string;
	attack_heli: string;
	transport_heli: string;
	transport_fw: string;
	transport_fw_heavy: string;
	bda_heli: string;
}
export interface GroundRoster {
	primary_slots: string[][];
	secondary_slots: string[][];
	arty_slots: string[][];
	mlrs_slots: string[][];
	infantry: Record<number, string>;
	garrison: Record<number, string[]>;
	ewr: Record<number, string>;
	aaa: Record<number, string>;
	sam: Record<number, string[]>;
}
export interface StaticKind {
	spawn: "static" | "unit";
	type?: string;
	shape?: string;
	cat?: string;
	unit?: Record<number, string>;
	label: string;
}
export interface CampaignConfig {
	mode: "campaign" | "skirmish";
	countries: Record<number, number>;
	types: { aircraft: Record<number, AircraftRoster>; ground: GroundRoster };
	statics: {
		kinds: Record<string, StaticKind>;
		palette: Record<string, string[]>;
		farp: { type: string; shape_name: string; category: string };
	};
	payloads: Record<
		number,
		{ striker: PylonData[]; escort: PylonData[]; attack_heli: PylonData[] }
	>;
	reserves: {
		per_base: InventoryLedger;
		farp_heli: number;
		farp_transport: number;
	};
	theatre: {
		farp_activation: boolean;
		fixed_wing_per_side: number;
		front_dist: number;
		farp_front_dist: number;
	};
	persistence: {
		enabled: boolean;
		autosave_period: number;
		slot: string;
		db_path: string;
	};
	defenses: {
		groups_per: { airbase: number; farp: number; installation: number };
		ring_radius: number;
		group: Record<number, string[]>;
		firing_points: { airbase: number; farp: number; installation: number };
		mg: Record<number, string>;
		manpad: Record<number, string>;
	};
}
const B = coalition.side.BLUE;
const R = coalition.side.RED;
// Stock DCS four-position heliport. MissionEditor/modules/me_exportToMiz.lua:922-950
// enumerates exactly four parking positions for this FARP subtype; the single
// and invisible FARP variants do not satisfy the campaign's section launches.
const STOCK_FOUR_SLOT_FARP = {
	type: "FARP",
	shape_name: "FARPS",
	category: "Heliports",
};
const primary = [
	["M-1 Abrams", "T-80UD"],
	["M-1 Abrams", "T-80UD"],
	["M2A2 Bradley", "BMP-2"],
	["M1097 Avenger", "2S6 Tunguska"],
	["M2A2 Bradley", "BMP-3"],
	["M48 Chaparral", "Strela-10M3"],
	["M-113", "BTR-80"],
	["M-1 Abrams", "T-80UD"],
	["M-1 Abrams", "T-80UD"],
	["M2A2 Bradley", "BMP-2"],
	["M-1 Abrams", "T-80UD"],
	["M-1 Abrams", "T-80UD"],
	["M-113", "BTR-80"],
	["M-1 Abrams", "T-80UD"],
	["M-113", "BTR-80"],
	["M-1 Abrams", "T-80UD"],
];
const secondary = [
	["M-1 Abrams", "T-80UD"],
	["M48 Chaparral", "Strela-10M3"],
	["M2A2 Bradley", "BMP-3"],
	["M 818", "Ural-375"],
	["M-1 Abrams", "T-80UD"],
	["M978 HEMTT Tanker", "ATZ-10"],
	["M1043 HMMWV Armament", "BRDM-2"],
	["M-113", "BTR-80"],
	["M-1 Abrams", "T-80UD"],
	["M 818", "Ural-375"],
	["M-113", "BTR-80"],
	["M48 Chaparral", "Strela-10M3"],
	["M-1 Abrams", "T-80UD"],
	["M978 HEMTT Tanker", "ATZ-10"],
	["M48 Chaparral", "Strela-10M3"],
	["M-1 Abrams", "T-80UD"],
];
const arty = [
	["M-109", "SAU Msta"],
	["M-109", "SAU Msta"],
	["M 818", "Ural-375"],
	["M1043 HMMWV Armament", "UAZ-469"],
];
const mlrs = [
	["MLRS", "Grad-URAL"],
	["MLRS", "Grad-URAL"],
	["M 818", "Ural-375"],
	["M1043 HMMWV Armament", "UAZ-469"],
];

function makeDefaults(): CampaignConfig {
	return {
		mode: "campaign",
		countries: { [B]: country.id.CJTF_BLUE, [R]: country.id.CJTF_RED },
		types: {
			aircraft: {
				[B]: {
					striker: "F-16C bl.52d",
					escort: "F-15C",
					recon: "F-15C",
					attack_heli: "AH-64D",
					transport_heli: "UH-60A",
					transport_fw: "C-130",
					transport_fw_heavy: "C-17A",
					bda_heli: "UH-60A",
				},
				[R]: {
					striker: "Su-25T",
					escort: "Su-27",
					recon: "Su-27",
					attack_heli: "Mi-24V",
					transport_heli: "Mi-8MT",
					transport_fw: "An-26B",
					transport_fw_heavy: "IL-76MD",
					bda_heli: "Mi-8MT",
				},
			},
			ground: {
				primary_slots: primary,
				secondary_slots: secondary,
				arty_slots: arty,
				mlrs_slots: mlrs,
				infantry: { [B]: "Soldier M4", [R]: "Infantry AK" },
				garrison: {
					[B]: [
						"M-1 Abrams",
						"M2A2 Bradley",
						"M2A2 Bradley",
						"M1043 HMMWV Armament",
					],
					[R]: ["T-80UD", "BMP-2", "BMP-2", "BTR-80"],
				},
				ewr: { [B]: "Hawk sr", [R]: "55G6 EWR" },
				aaa: { [B]: "Vulcan", [R]: "ZSU-23-4 Shilka" },
				sam: { [B]: ["Roland ADS"], [R]: ["Kub 1S91 str", "Kub 2P25 ln"] },
			},
		},
		statics: {
			kinds: {
				depot: {
					spawn: "static",
					type: "M92_10Ft_Container",
					shape: "M92_Container_10ft",
					cat: "Cargos",
					label: "Supply Depot",
				},
				fuel: {
					spawn: "static",
					type: "FARP Fuel Depot",
					shape: "GSM Rus",
					cat: "Fortifications",
					label: "Fuel Depot",
				},
				command: {
					spawn: "static",
					type: ".Command Center",
					shape: "ComCenter",
					cat: "Fortifications",
					label: "Command Post",
				},
				factory: {
					spawn: "static",
					type: "Boiler-house A",
					shape: "kotelnaya_a",
					cat: "Fortifications",
					label: "Munitions Factory",
				},
				refinery: {
					spawn: "static",
					type: "FARP Fuel Depot",
					shape: "GSM Rus",
					cat: "Fortifications",
					label: "Oil Refinery",
				},
				radar: {
					spawn: "unit",
					unit: { [B]: "Hawk sr", [R]: "55G6 EWR" },
					label: "Radar/EWR",
				},
			},
			palette: {
				factory: ["Boiler-house A", "kotelnaya_a", "Fortifications"],
				warehouse: ["Warehouse", "sklad", "Warehouses"],
				fueltank: ["Tank", "bak", "Warehouses"],
				ammo: [".Ammunition depot", "SkladC", "Warehouses"],
				fuel: ["FARP Fuel Depot", "GSM Rus", "Fortifications"],
				command: [".Command Center", "ComCenter", "Fortifications"],
				bunker: ["FARP CP Blindage", "kp_ug", "Fortifications"],
				container: ["M92_10Ft_Container", "M92_Container_10ft", "Cargos"],
			},
			farp: { ...STOCK_FOUR_SLOT_FARP },
		},
		payloads: {
			[B]: {
				striker: payloads.F16_STRIKER,
				escort: payloads.F15_ESCORT,
				attack_heli: payloads.AH64D_CAP,
			},
			[R]: {
				striker: payloads.SU25T_STRIKER,
				escort: payloads.SU27_ESCORT,
				attack_heli: payloads.MI24V_CAP,
			},
		},
		reserves: {
			per_base: {
				striker: 4,
				escort: 2,
				heli: 6,
				recon: 1,
				transport: 3,
				vehicle: 2,
			},
			farp_heli: 4,
			farp_transport: 2,
		},
		theatre: {
			farp_activation: true,
			fixed_wing_per_side: 2,
			front_dist: 140000,
			farp_front_dist: 260000,
		},
		persistence: {
			enabled: false,
			autosave_period: 300,
			slot: "default",
			db_path: "dmt_campaign.sqlite",
		},
		defenses: {
			groups_per: { airbase: 3, farp: 1, installation: 1 },
			ring_radius: 1500,
			group: {
				[B]: ["M48 Chaparral", "Vulcan"],
				[R]: ["2S6 Tunguska", "Strela-10M3"],
			},
			firing_points: { airbase: 4, farp: 2, installation: 2 },
			mg: { [B]: "Soldier M4", [R]: "Infantry AK" },
			manpad: { [B]: "Soldier stinger", [R]: "SA-18 Igla manpad" },
		},
	};
}

// DMT_CONFIG is deliberately accepted only after structural validation. A malformed override leaves
// the cited defaults active rather than silently corrupting a nested campaign contract.
export const DEF: CampaignConfig = makeDefaults();
export const C: CampaignConfig = makeDefaults();
const overrideWarnings: string[] = [];

interface LuaConfigTable extends Record<string, unknown>, Array<unknown> {}
function isLuaConfigTable(value: unknown): value is LuaConfigTable {
	return type(value) === "table";
}
function objectValue(value: unknown): Record<string, unknown> | undefined {
	if (value === undefined) return undefined;
	if (isLuaConfigTable(value)) return value;
	overrideWarnings.push("ignored malformed table override");
	return undefined;
}
// Match the original Lua diagnostic: one applied override is one leaf value,
// regardless of how deeply it is nested in DMT_CONFIG.
function countOverrideLeaves(value: unknown): number {
	if (!isLuaConfigTable(value)) return 1;
	let count = 0;
	for (const child of Object.values(value)) count += countOverrideLeaves(child);
	return count;
}
function numberValue(
	table: Record<string, unknown> | undefined,
	key: string,
	fallback: number,
): number {
	const value = table?.[key];
	if (value === undefined) return fallback;
	if (typeof value === "number") return value;
	overrideWarnings.push(`ignored non-number override for ${key}`);
	return fallback;
}
function stringValue(
	table: Record<string, unknown> | undefined,
	key: string,
	fallback: string,
): string {
	const value = table?.[key];
	if (value === undefined) return fallback;
	if (typeof value === "string") return value;
	overrideWarnings.push(`ignored non-string override for ${key}`);
	return fallback;
}
function booleanValue(
	table: Record<string, unknown> | undefined,
	key: string,
	fallback: boolean,
): boolean {
	const value = table?.[key];
	if (value === undefined) return fallback;
	if (typeof value === "boolean") return value;
	overrideWarnings.push(`ignored non-boolean override for ${key}`);
	return fallback;
}
function stringList(value: unknown, fallback: string[]): string[] {
	if (value === undefined) return fallback;
	if (!isLuaConfigTable(value)) {
		overrideWarnings.push("ignored malformed string-list override");
		return fallback;
	}
	const result: string[] = [];
	for (const item of value) {
		if (typeof item !== "string") {
			overrideWarnings.push("ignored malformed string-list member");
			return fallback;
		}
		result.push(item);
	}
	return result.length > 0 ? result : fallback;
}
function slotList(value: unknown, fallback: string[][]): string[][] {
	if (value === undefined) return fallback;
	if (!isLuaConfigTable(value)) {
		overrideWarnings.push("ignored malformed slot-list override");
		return fallback;
	}
	const result: string[][] = [];
	for (const row of value) {
		const values = stringList(row, []);
		if (values.length !== 2) {
			overrideWarnings.push("ignored slot row not containing two sides");
			return fallback;
		}
		result.push(values);
	}
	return result.length > 0 ? result : fallback;
}
function pylonList(value: unknown, fallback: PylonData[]): PylonData[] {
	if (value === undefined) return fallback;
	if (!isLuaConfigTable(value)) {
		overrideWarnings.push("ignored malformed pylon-list override");
		return fallback;
	}
	const result: PylonData[] = [];
	for (const item of value) {
		const row = objectValue(item);
		if (
			!row ||
			typeof row.CLSID !== "string" ||
			(row.num !== undefined && typeof row.num !== "number")
		) {
			overrideWarnings.push("ignored malformed pylon row");
			return fallback;
		}
		result.push({ CLSID: row.CLSID, num: row.num });
	}
	return result.length > 0 ? result : fallback;
}
function applySideStrings(
	source: Record<string, unknown> | undefined,
	target: Record<number, string>,
): void {
	target[B] = stringValue(source, "blue", target[B]);
	target[R] = stringValue(source, "red", target[R]);
}
function applySideLists(
	source: Record<string, unknown> | undefined,
	target: Record<number, string[]>,
): void {
	target[B] = stringList(source?.blue, target[B]);
	target[R] = stringList(source?.red, target[R]);
}
function applyOverrides(source: Record<string, unknown> | undefined): void {
	if (!source) return;
	if (source.mode === "campaign" || source.mode === "skirmish")
		C.mode = source.mode;
	else if (source.mode !== undefined)
		overrideWarnings.push(
			"ignored invalid mode override (expected campaign or skirmish)",
		);
	const countries = objectValue(source.countries);
	C.countries[B] = numberValue(countries, "blue", C.countries[B]);
	C.countries[R] = numberValue(countries, "red", C.countries[R]);
	const types = objectValue(source.types),
		aircraft = objectValue(types?.aircraft);
	const sideRows: Array<[string, Side]> = [
		["blue", B],
		["red", R],
	];
	for (const [key, side] of sideRows) {
		const row = objectValue(aircraft?.[key]),
			active = C.types.aircraft[side];
		active.striker = stringValue(row, "striker", active.striker);
		active.escort = stringValue(row, "escort", active.escort);
		active.recon = stringValue(row, "recon", active.recon);
		active.attack_heli = stringValue(row, "attack_heli", active.attack_heli);
		active.transport_heli = stringValue(
			row,
			"transport_heli",
			active.transport_heli,
		);
		active.transport_fw = stringValue(row, "transport_fw", active.transport_fw);
		active.transport_fw_heavy = stringValue(
			row,
			"transport_fw_heavy",
			active.transport_fw_heavy,
		);
		active.bda_heli = stringValue(row, "bda_heli", active.bda_heli);
	}
	const ground = objectValue(types?.ground);
	C.types.ground.primary_slots = slotList(
		ground?.primary_slots,
		C.types.ground.primary_slots,
	);
	C.types.ground.secondary_slots = slotList(
		ground?.secondary_slots,
		C.types.ground.secondary_slots,
	);
	C.types.ground.arty_slots = slotList(
		ground?.arty_slots,
		C.types.ground.arty_slots,
	);
	C.types.ground.mlrs_slots = slotList(
		ground?.mlrs_slots,
		C.types.ground.mlrs_slots,
	);
	applySideStrings(objectValue(ground?.infantry), C.types.ground.infantry);
	applySideLists(objectValue(ground?.garrison), C.types.ground.garrison);
	applySideStrings(objectValue(ground?.ewr), C.types.ground.ewr);
	applySideStrings(objectValue(ground?.aaa), C.types.ground.aaa);
	applySideLists(objectValue(ground?.sam), C.types.ground.sam);
	const statics = objectValue(source.statics),
		kindRows = objectValue(statics?.kinds);
	for (const [name, value] of Object.entries(kindRows ?? {})) {
		const row = objectValue(value);
		if (!row) continue;
		const active = C.statics.kinds[name] ?? {
			spawn: "static",
			label: name,
		};
		if (row.spawn === "static" || row.spawn === "unit")
			active.spawn = row.spawn;
		if (typeof row.type === "string") active.type = row.type;
		if (typeof row.shape === "string") active.shape = row.shape;
		if (typeof row.cat === "string") active.cat = row.cat;
		active.label = stringValue(row, "label", active.label);
		if (objectValue(row.unit) && !active.unit) active.unit = {};
		if (active.unit) applySideStrings(objectValue(row.unit), active.unit);
		C.statics.kinds[name] = active;
	}
	const palette = objectValue(statics?.palette);
	if (palette)
		for (const [name, value] of Object.entries(palette)) {
			const parsed = stringList(value, C.statics.palette[name] ?? []);
			if (parsed.length > 0) C.statics.palette[name] = parsed;
		}
	const farp = objectValue(statics?.farp);
	if (
		farp !== undefined &&
		(farp.type !== undefined ||
			farp.shape_name !== undefined ||
			farp.category !== undefined)
	)
		overrideWarnings.push(
			"ignored statics.farp override; generated bases require the stock four-slot FARP/FARPS heliport",
		);
	const configuredPayloads = objectValue(source.payloads);
	for (const [key, side] of sideRows) {
		const row = objectValue(configuredPayloads?.[key]),
			active = C.payloads[side];
		active.striker = pylonList(row?.striker, active.striker);
		active.escort = pylonList(row?.escort, active.escort);
		active.attack_heli = pylonList(row?.attack_heli, active.attack_heli);
	}
	const reserves = objectValue(source.reserves),
		perBase = objectValue(reserves?.per_base);
	const roles: Array<keyof InventoryLedger> = [
		"striker",
		"escort",
		"heli",
		"recon",
		"transport",
		"vehicle",
	];
	for (const role of roles)
		C.reserves.per_base[role] = numberValue(
			perBase,
			role,
			C.reserves.per_base[role],
		);
	C.reserves.farp_heli = numberValue(
		reserves,
		"farp_heli",
		C.reserves.farp_heli,
	);
	C.reserves.farp_transport = numberValue(
		reserves,
		"farp_transport",
		C.reserves.farp_transport,
	);
	const theatre = objectValue(source.theatre);
	C.theatre.farp_activation = booleanValue(
		theatre,
		"farp_activation",
		C.theatre.farp_activation,
	);
	C.theatre.fixed_wing_per_side = numberValue(
		theatre,
		"fixed_wing_per_side",
		C.theatre.fixed_wing_per_side,
	);
	C.theatre.front_dist = numberValue(
		theatre,
		"front_dist",
		C.theatre.front_dist,
	);
	C.theatre.farp_front_dist = numberValue(
		theatre,
		"farp_front_dist",
		C.theatre.farp_front_dist,
	);
	const persistence = objectValue(source.persistence);
	C.persistence.enabled = booleanValue(
		persistence,
		"enabled",
		C.persistence.enabled,
	);
	C.persistence.autosave_period = numberValue(
		persistence,
		"autosave_period",
		C.persistence.autosave_period,
	);
	C.persistence.slot = stringValue(persistence, "slot", C.persistence.slot);
	C.persistence.db_path = stringValue(
		persistence,
		"db_path",
		C.persistence.db_path,
	);
	const defenses = objectValue(source.defenses),
		groups = objectValue(defenses?.groups_per),
		firing = objectValue(defenses?.firing_points);
	C.defenses.groups_per.airbase = numberValue(
		groups,
		"airbase",
		C.defenses.groups_per.airbase,
	);
	C.defenses.groups_per.farp = numberValue(
		groups,
		"farp",
		C.defenses.groups_per.farp,
	);
	C.defenses.groups_per.installation = numberValue(
		groups,
		"installation",
		C.defenses.groups_per.installation,
	);
	C.defenses.ring_radius = numberValue(
		defenses,
		"ring_radius",
		C.defenses.ring_radius,
	);
	applySideLists(objectValue(defenses?.group), C.defenses.group);
	applySideStrings(objectValue(defenses?.mg), C.defenses.mg);
	applySideStrings(objectValue(defenses?.manpad), C.defenses.manpad);
	C.defenses.firing_points.airbase = numberValue(
		firing,
		"airbase",
		C.defenses.firing_points.airbase,
	);
	C.defenses.firing_points.farp = numberValue(
		firing,
		"farp",
		C.defenses.firing_points.farp,
	);
	C.defenses.firing_points.installation = numberValue(
		firing,
		"installation",
		C.defenses.firing_points.installation,
	);
}
const userConfig = objectValue(_G.DMT_CONFIG);
applyOverrides(userConfig);
_G.DMT_ACTIVE_CONFIG = C;

export function load_and_validate(
	log_fn: (message: string) => void = () => undefined,
): CampaignConfig {
	for (const warning of overrideWarnings) {
		log_fn(`config: ${warning}`);
		cs.dbg("config", "%s", warning);
	}
	const missing: Record<string, boolean> = {},
		okay: Record<string, boolean> = {};
	const dbExists = (name: string): boolean => {
		try {
			const desc = Unit.getDescByName(name);
			if (!desc) return false;
			return (
				(desc.displayName !== undefined && desc.displayName.length > 0) ||
				Object.keys(desc.attributes ?? {}).length > 0
			);
		} catch (_error) {
			return false;
		}
	};
	const note = (name: string): boolean => {
		const exists = dbExists(name);
		if (exists) okay[name] = true;
		else missing[name] = true;
		return exists;
	};
	const validateScalar = (
		active: Record<number, string>,
		defaults: Record<number, string>,
		side: Side,
		path: string,
	): void => {
		const current = active[side];
		if (note(current)) return;
		if (current !== defaults[side]) {
			cs.dbg(
				"config",
				"INVALID: %s = %s (unknown unit type) — using default",
				path,
				current,
			);
			delete missing[current];
			active[side] = defaults[side];
			note(active[side]);
		}
	};
	const validateList = (
		active: Record<number, string[]>,
		defaults: Record<number, string[]>,
		side: Side,
		path: string,
	): void => {
		const bad = active[side].filter((name) => !dbExists(name));
		if (bad.length === 0) {
			for (const name of active[side]) note(name);
			return;
		}
		if (active[side].join("\0") !== defaults[side].join("\0")) {
			cs.dbg(
				"config",
				"INVALID: %s (unknown unit type: %s) — using default",
				path,
				bad.join(", "),
			);
			active[side] = defaults[side];
		}
		for (const name of active[side]) note(name);
	};
	const roles: Array<keyof AircraftRoster> = [
		"striker",
		"escort",
		"recon",
		"attack_heli",
		"transport_heli",
		"transport_fw",
		"transport_fw_heavy",
		"bda_heli",
	];
	const combatSides: Side[] = [B, R];
	for (const side of combatSides) {
		for (const role of roles) {
			const current = C.types.aircraft[side][role];
			if (note(current)) continue;
			const fallback = DEF.types.aircraft[side][role];
			if (current !== fallback) {
				cs.dbg(
					"config",
					"INVALID: types.aircraft.%s.%s = %s — using default",
					cs.SIDE_NAME[side],
					role,
					current,
				);
				delete missing[current];
				C.types.aircraft[side][role] = fallback;
				note(fallback);
			}
		}
		validateScalar(
			C.types.ground.infantry,
			DEF.types.ground.infantry,
			side,
			`types.ground.infantry.${cs.SIDE_NAME[side]}`,
		);
		validateScalar(
			C.types.ground.ewr,
			DEF.types.ground.ewr,
			side,
			`types.ground.ewr.${cs.SIDE_NAME[side]}`,
		);
		validateScalar(
			C.types.ground.aaa,
			DEF.types.ground.aaa,
			side,
			`types.ground.aaa.${cs.SIDE_NAME[side]}`,
		);
		validateList(
			C.types.ground.garrison,
			DEF.types.ground.garrison,
			side,
			`types.ground.garrison.${cs.SIDE_NAME[side]}`,
		);
		validateList(
			C.types.ground.sam,
			DEF.types.ground.sam,
			side,
			`types.ground.sam.${cs.SIDE_NAME[side]}`,
		);
		validateList(
			C.defenses.group,
			DEF.defenses.group,
			side,
			`defenses.group.${cs.SIDE_NAME[side]}`,
		);
		validateScalar(
			C.defenses.mg,
			DEF.defenses.mg,
			side,
			`defenses.mg.${cs.SIDE_NAME[side]}`,
		);
		validateScalar(
			C.defenses.manpad,
			DEF.defenses.manpad,
			side,
			`defenses.manpad.${cs.SIDE_NAME[side]}`,
		);
	}
	const validateSlots = (
		key: "primary_slots" | "secondary_slots" | "arty_slots" | "mlrs_slots",
	): void => {
		const active = C.types.ground[key];
		let invalid = false;
		for (const row of active)
			for (const name of row) if (!dbExists(name)) invalid = true;
		if (invalid && active !== DEF.types.ground[key]) {
			cs.dbg(
				"config",
				"INVALID: types.ground.%s contains unknown unit — using default",
				key,
			);
			C.types.ground[key] = DEF.types.ground[key];
		}
		for (const row of C.types.ground[key]) for (const name of row) note(name);
	};
	validateSlots("primary_slots");
	validateSlots("secondary_slots");
	validateSlots("arty_slots");
	validateSlots("mlrs_slots");
	const reserveRoles: Array<keyof InventoryLedger> = [
		"striker",
		"escort",
		"heli",
		"recon",
		"transport",
		"vehicle",
	];
	for (const role of reserveRoles)
		if (C.reserves.per_base[role] < 0)
			C.reserves.per_base[role] = DEF.reserves.per_base[role];
	if (C.reserves.farp_heli < 0) C.reserves.farp_heli = DEF.reserves.farp_heli;
	if (C.reserves.farp_transport < 0)
		C.reserves.farp_transport = DEF.reserves.farp_transport;
	const validCountries = Object.values(country.id);
	for (const side of combatSides)
		if (!validCountries.includes(C.countries[side])) {
			cs.dbg(
				"config",
				"INVALID: countries.%s = %s — using default",
				cs.SIDE_NAME[side],
				C.countries[side],
			);
			C.countries[side] = DEF.countries[side];
		}
	const missionCoalitions = env.mission?.coalitions;
	for (const side of combatSides) {
		const roster =
			side === B ? missionCoalitions?.blue : missionCoalitions?.red;
		if (roster !== undefined && !roster.includes(C.countries[side])) {
			const warning = string.format(
				"[dmt:config] WARNING: country %d is not assigned to %s in this mission; spawned units may be neutral or on the wrong side.",
				C.countries[side],
				cs.SIDE_NAME[side],
			);
			env.info(warning);
			log_fn(warning);
		}
	}
	if (
		C.theatre.fixed_wing_per_side < 0 ||
		C.theatre.fixed_wing_per_side !== Math.floor(C.theatre.fixed_wing_per_side)
	)
		C.theatre.fixed_wing_per_side = DEF.theatre.fixed_wing_per_side;
	if (C.theatre.front_dist < 0) C.theatre.front_dist = DEF.theatre.front_dist;
	if (C.theatre.farp_front_dist < 0)
		C.theatre.farp_front_dist = DEF.theatre.farp_front_dist;
	if (C.persistence.autosave_period <= 0)
		C.persistence.autosave_period = DEF.persistence.autosave_period;
	if (C.persistence.slot.length === 0)
		C.persistence.slot = DEF.persistence.slot;
	if (C.persistence.db_path.length === 0)
		C.persistence.db_path = DEF.persistence.db_path;
	const defenseKeys: Array<"airbase" | "farp" | "installation"> = [
		"airbase",
		"farp",
		"installation",
	];
	for (const key of defenseKeys) {
		if (C.defenses.groups_per[key] < 0)
			C.defenses.groups_per[key] = DEF.defenses.groups_per[key];
		if (C.defenses.firing_points[key] < 0)
			C.defenses.firing_points[key] = DEF.defenses.firing_points[key];
	}
	if (C.defenses.ring_radius < 0)
		C.defenses.ring_radius = DEF.defenses.ring_radius;
	const knownCategories: Record<string, boolean> = {
		Fortifications: true,
		Warehouses: true,
		Cargos: true,
		Heliports: true,
		Fortification: true,
		GroundVehicles: true,
	};
	for (const [name, spec] of Object.entries(C.statics.kinds))
		if (
			spec.spawn === "static" &&
			(spec.type === undefined ||
				spec.shape === undefined ||
				spec.cat === undefined ||
				knownCategories[spec.cat] !== true)
		) {
			cs.dbg(
				"config",
				"INVALID: statics.kinds.%s type/shape/category — using default",
				name,
			);
			C.statics.kinds[name] = DEF.statics.kinds[name];
		}
	for (const [name, triple] of Object.entries(C.statics.palette))
		if (triple.length !== 3 || knownCategories[triple[2]] !== true) {
			cs.dbg(
				"config",
				"INVALID: statics.palette.%s triple — using default",
				name,
			);
			C.statics.palette[name] = DEF.statics.palette[name];
		}
	if (knownCategories[C.statics.farp.category] !== true)
		C.statics.farp = DEF.statics.farp;
	const missingNames = Object.keys(missing).filter(
		(name) => okay[name] !== true,
	);
	const warning =
		missingNames.length > 0
			? string.format(
					"[dmt:config] WARNING: %d unit type(s) NOT in this DCS install's DB: %s. Their spawns will FAIL.",
					missingNames.length,
					missingNames.sort().join(", "),
				)
			: undefined;
	if (warning) {
		env.info(warning);
		log_fn(warning);
		try {
			trigger.action.outText(warning, 30);
		} catch (_error) {}
	}
	const summary = string.format(
		"[dmt:config] validated: %d unit types OK, %d unknown, %d user overrides applied",
		Object.keys(okay).length,
		missingNames.length,
		userConfig ? countOverrideLeaves(userConfig) : 0,
	);
	env.info(summary);
	log_fn(summary);
	cs.dbg(
		"config",
		"load_and_validate complete: ok=%d missing=%d",
		Object.keys(okay).length,
		missingNames.length,
	);
	return C;
}
