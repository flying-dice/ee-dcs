/** @noSelfInFile */
/*
-- imap.lua
-- EECH source: aphavoc/source/ai/highlevl/imaps.c
--   initialise_imaps(), normalise_importance_imaps(), normalise_base_distance_imaps(),
--   normalise_air_defence_imaps(), normalise_surface_defence_imaps(),
--   normalise_inlfuence_map() (min-max normalise to 0–255 then / 255.0),
--   update_keysite_distance_to_friendly_base() — inverse-square falloff within air_coverage_radius,
--   update_imap_surface_to_air_defence_level()  — AIR_SCAN_RANGE * 10 exaggeration,
--   update_imap_surface_to_surface_defence_level() — SURFACE_SCAN_RANGE * 10 exaggeration.
--
-- DCS proxy: EECH stores values in a 2D sector grid.  DCS has no sector grid, so we
-- compute per-base proxy values using the same falloff formulas; imap.get() interpolates
-- for any world position via inverse-distance weighting from the known base positions.
--
-- Layers (string keys, mirrors imap_types enum):
--   M.BASE_DISTANCE  — proximity to friendly bases (inverse-square within air_coverage_radius)
--   M.AIR_DEFENCE    — enemy AA threat coverage (AIR_SCAN_RANGE × 10 exaggeration)
--   M.SURFACE_DEFENCE— enemy surface-to-surface threat (SURFACE_SCAN_RANGE × 10)
--   M.IMPORTANCE     — keysite strategic importance (health × ownership)
--
-- Period: each layer refreshes every 120 s, staggered 20 s apart (mirrors EECH's
--         separate update_imap_* calls registered at different offsets).
*/
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import { BLUE, RED } from "./sides";

const S = cs.S;
export const BASE_DISTANCE = "BASE_DISTANCE";
export const AIR_DEFENCE = "AIR_DEFENCE";
export const SURFACE_DEFENCE = "SURFACE_DEFENCE";
export const IMPORTANCE = "IMPORTANCE";
export type Layer =
	| typeof BASE_DISTANCE
	| typeof AIR_DEFENCE
	| typeof SURFACE_DEFENCE
	| typeof IMPORTANCE;
const AIR_COVERAGE_RADIUS = 150000;
const IMPORTANCE_RADIUS = 100000;
const AIR_SCAN_EXAGGERATION = 10.0;
const SURF_SCAN_EXAGGERATION = 10.0;
const DEFAULT_AIR_SCAN_RANGE = 25000;
const DEFAULT_SURF_SCAN_RANGE = 15000;
const UPDATE_PERIOD = 120;
const LAYER_STAGGER = 20;
const IMAP_INITIAL_DELAY_SECONDS = 20; // preserved Lua scheduler base offset
const LAYERS: Layer[] = [
	BASE_DISTANCE,
	AIR_DEFENCE,
	SURFACE_DEFENCE,
	IMPORTANCE,
];
const SIDES: Side[] = [BLUE, RED];

function ensureTables(): void {
	for (const layer of LAYERS) {
		S.imap.raw[layer] ??= {
			[BLUE]: {},
			[RED]: {},
		};
		S.imap.nrm[layer] ??= {
			[BLUE]: {},
			[RED]: {},
		};
		for (const side of SIDES) {
			S.imap.raw[layer][side] ??= {};
			S.imap.nrm[layer][side] ??= {};
		}
	}
}
function raw(layer: Layer, side: Side): Record<string, number> {
	return S.imap.raw[layer][side];
}
function nrm(layer: Layer, side: Side): Record<string, number> {
	return S.imap.nrm[layer][side];
}
function normalise(layer: Layer, side: Side): void {
	let min = math.huge;
	let max = -math.huge;
	for (const value of Object.values(raw(layer, side))) {
		if (value < min) min = value;
		if (value > max) max = value;
	}
	if (max === min) return;
	for (const [name, value] of Object.entries(raw(layer, side)))
		nrm(layer, side)[name] = (value - min) / (max - min);
}
function reset(layer: Layer, side: Side): Record<string, number> {
	const values = raw(layer, side);
	for (const name of Object.keys(S.base_owner)) values[name] = 0;
	return values;
}
function updateBaseDistance(side: Side): void {
	const values = reset(BASE_DISTANCE, side);
	const radius2 = AIR_COVERAGE_RADIUS ** 2;
	for (const [friendly, owner] of Object.entries(S.base_owner))
		if (owner === side) {
			const from = S.base_pos[friendly];
			if (!from) continue;
			for (const name of Object.keys(S.base_owner)) {
				const to = S.base_pos[name];
				if (!to) continue;
				const dx = from.x - to.x;
				const dz = from.z - to.z;
				const d2 = dx * dx + dz * dz;
				if (d2 < radius2)
					values[name] = Math.max(values[name] ?? 0, 1 - d2 / radius2);
			}
		}
	normalise(BASE_DISTANCE, side);
}
function updateThreat(
	side: Side,
	layer: typeof AIR_DEFENCE | typeof SURFACE_DEFENCE,
): void {
	const values = reset(layer, side);
	const radius =
		layer === AIR_DEFENCE
			? DEFAULT_AIR_SCAN_RANGE * AIR_SCAN_EXAGGERATION
			: DEFAULT_SURF_SCAN_RANGE * SURF_SCAN_EXAGGERATION;
	const radius2 = radius * radius;
	for (const group of coalition.getGroups(cs.ENEMY[side]) ?? []) {
		if (!group?.isExist()) continue;
		const unit = group.getUnit(1);
		if (!unit) continue;
		const attributes = unit.getDesc()?.attributes ?? {};
		const relevant =
			layer === AIR_DEFENCE
				? attributes["SAM"] ||
					attributes["AAA"] ||
					attributes["SR SAM"] ||
					attributes["IR Guided SAM"] ||
					attributes["LR SAM"] ||
					attributes["MR SAM"]
				: attributes["Armor"] ||
					attributes["Artillery"] ||
					attributes["Infantry"] ||
					attributes["Ground vehicles"];
		if (relevant !== true || !unit.isExist()) continue;
		const pos = unit.getPosition().p;
		for (const name of Object.keys(S.base_owner)) {
			const base = S.base_pos[name];
			if (!base) continue;
			const dx = pos.x - base.x;
			const dz = pos.z - base.z;
			const d2 = dx * dx + dz * dz;
			if (d2 < radius2) values[name] = (values[name] ?? 0) + (1 - d2 / radius2);
		}
	}
	normalise(layer, side);
}
function updateImportance(side: Side): void {
	const values = reset(IMPORTANCE, side);
	const radius2 = IMPORTANCE_RADIUS ** 2;
	for (const [friendly, owner] of Object.entries(S.base_owner))
		if (owner === side) {
			const from = S.base_pos[friendly];
			if (!from) continue;
			const importance = (S.base_health[friendly] ?? 1) * 0.5 + 0.5;
			for (const name of Object.keys(S.base_owner)) {
				const to = S.base_pos[name];
				if (!to) continue;
				const dx = from.x - to.x;
				const dz = from.z - to.z;
				const d2 = dx * dx + dz * dz;
				if (d2 < radius2)
					values[name] = (values[name] ?? 0) + (1 - d2 / radius2) * importance;
			}
		}
	normalise(IMPORTANCE, side);
}
export function get(side: Side, layer: Layer, wp?: WorldPoint): number {
	if (!wp) return 0;
	const values = S.imap.nrm[layer]?.[side];
	if (!values) return 0;
	let numerator = 0;
	let denominator = 0;
	for (const [name, value] of Object.entries(values)) {
		const base = S.base_pos[name];
		if (!base) continue;
		const dx = wp.x - base.x;
		const dz = wp.z - base.z;
		const d2 = dx * dx + dz * dz;
		if (d2 < 1) return value;
		const weight = 1 / d2;
		numerator += weight * value;
		denominator += weight;
	}
	return denominator === 0 ? 0 : numerator / denominator;
}
export function init(): void {
	ensureTables();
	for (const layer of LAYERS)
		for (const side of SIDES) {
			S.imap.raw[layer][side] = {};
			S.imap.nrm[layer][side] = {};
		}
}
export function schedule_update(
	log_fn: (message: string) => void = () => undefined,
): void {
	const generation = cs.GENERATION;
	const updaters: Array<[Layer, string, (side: Side) => void]> = [
		[BASE_DISTANCE, "base_distance", updateBaseDistance],
		[AIR_DEFENCE, "air_defence", (side) => updateThreat(side, AIR_DEFENCE)],
		[
			SURFACE_DEFENCE,
			"surface_defence",
			(side) => updateThreat(side, SURFACE_DEFENCE),
		],
		[IMPORTANCE, "importance", updateImportance],
	];
	updaters.forEach(([layer, label, update], index) => {
		timer.scheduleFunction(
			(_arg, time) => {
				if (_DMT_GEN !== generation) return undefined;
				try {
					for (const side of SIDES) update(side);
				} catch (error) {
					log_fn(`imap ${label} error: ${tostring(error)}`);
				}
				cs.dbg(
					"imap",
					"layer %s refreshed: BLUE=%d entries, RED=%d entries",
					label,
					Object.keys(nrm(layer, BLUE)).length,
					Object.keys(nrm(layer, RED)).length,
				);
				return time + UPDATE_PERIOD;
			},
			undefined,
			timer.getTime() + IMAP_INITIAL_DELAY_SECONDS + index * LAYER_STAGGER,
		);
	});
}
