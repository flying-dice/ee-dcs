/** @noSelfInFile */
/*
-- fog_of_war.lua
-- EECH source: aphavoc/source/entity/special/sector/sector.c
--   update_client_server_sector_fog_of_war() line 562
--   update_sector_fog_of_war() line 533  — subtracts FOG_OF_WAR_DECAY_RATE every period
--   set_sector_fog_of_war_value() line 374 — units grant fog proportional to (1-r/recon_radius)*maximum
-- EECH source: aphavoc/source/ai/highlevl/highlevl.h
--   FOG_OF_WAR_DECAY_RATE    = 30.0
--   DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE = 4.0 * ONE_HOUR = 4.0 * 3600 = 14400
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c line 280
--   add_high_level_ai_function(update_client_server_sector_fog_of_war, FOG_OF_WAR_DECAY_RATE, 8.0)
--   → period = 30 s, initial offset = 8 s
-- EECH source: highlevl.c FOW threshold usage:
--   line 1433, 1620, 2072, 2653, 3062: fow >= 0.25 * maximum  → proceed with task
--   line 1179: fow < 0.25 * maximum  → create recon instead
--   line 1819: fow < 0.20 * maximum  → create recon instead (troop insertion, stricter)
--
-- DCS proxy: EECH stores per-sector fog values.  DCS has no sector grid, so we track
-- per-base fog-of-war for each side.  Units within RECON_RADIUS of a base grant fog.
-- Normalised value returned by get() is raw / FOW_MAX (0.0–1.0).
*/
import * as cs from "./campaign_state";
import type { Side } from "./campaign_types";
import { BLUE, RED } from "./sides";

const S = cs.S;
const FOW_DECAY_RATE = 30.0;
const FOW_MAX = 4.0 * 3600;
const FOW_PERIOD = FOW_DECAY_RATE;
const FOW_OFFSET = 8.0;
const RECON = {
	FIGHTER: 10000,
	ATTACK_JET: 6000,
	HELI_ATTACK: 5000,
	HELI_TRANSPORT: 3000,
	INFANTRY: 500,
	VEHICLE: 1000,
	APC_IFV: 2000,
	SCOUT: 3000,
	AD_RADAR: 4000,
	RADAR_SAM: 6000,
	CAPITAL_SHIP: 8000,
};
export const THRESHOLD_TASK = 0.25;
export const THRESHOLD_TROOP = 0.2;
const SIDES: Side[] = [BLUE, RED];

function reconRadius(unit: Unit, category: number | undefined): number {
	const a = unit.getDesc()?.attributes ?? {};
	if (category === Group.Category.AIRPLANE) {
		if (a["Transports"]) return RECON.HELI_TRANSPORT;
		if (a["Attack planes"]) return RECON.ATTACK_JET;
		return RECON.FIGHTER;
	}
	if (category === Group.Category.HELICOPTER)
		return a["Transport helicopters"]
			? RECON.HELI_TRANSPORT
			: RECON.HELI_ATTACK;
	if (category === Group.Category.SHIP)
		return a["Aircraft Carriers"] ? RECON.CAPITAL_SHIP : RECON.RADAR_SAM;
	if (a["Infantry"]) return RECON.INFANTRY;
	if (a["SAM TR"] || a["SAM LR"]) return RECON.RADAR_SAM;
	if (a["SAM SR"]) return RECON.AD_RADAR;
	if (a["IFV"] || a["APC"]) return RECON.APC_IFV;
	return RECON.VEHICLE;
}
export function init(): void {
	for (const name of Object.keys(S.base_owner)) {
		S.fow[name] ??= {};
		for (const side of SIDES) S.fow[name][side] ??= 0;
	}
}
export function get(base_name: string, side: Side): number {
	if (S.base_owner[base_name] === side) return 1;
	return (S.fow[base_name]?.[side] ?? 0) / FOW_MAX;
}
function tick(): void {
	let grants = 0;
	for (const name of Object.keys(S.base_owner)) {
		const base = S.base_pos[name];
		S.fow[name] ??= {};
		for (const side of SIDES)
			S.fow[name][side] = Math.max(
				0,
				(S.fow[name][side] ?? 0) - FOW_DECAY_RATE,
			);
		if (!base) continue;
		for (const side of SIDES)
			for (const group of coalition.getGroups(side) ?? []) {
				if (!group?.isExist()) continue;
				const unit = group.getUnit(1);
				if (!unit?.isExist()) continue;
				const pos = unit.getPosition().p;
				const dx = pos.x - base.x;
				const dz = pos.z - base.z;
				const distance = Math.sqrt(dx * dx + dz * dz);
				const scan = reconRadius(unit, group.getCategory()) * 2;
				if (distance <= scan) {
					const grant = (1 - distance / scan) * FOW_MAX;
					const current = S.fow[name][side] ?? 0;
					if (grant > current) {
						S.fow[name][side] = Math.min(FOW_MAX, grant);
						grants += 1;
					}
				}
			}
	}
	cs.dbg(
		"fow",
		"decay+recon tick: %d (base,side) FOW grants raised this pass",
		grants,
	);
}
export function schedule_decay(
	log_fn: (message: string) => void = () => undefined,
): void {
	const generation = cs.GENERATION;
	cs.dbg(
		"fow",
		"decay scheduler REGISTERED offset=%.0fs period=%.0fs",
		FOW_OFFSET,
		FOW_PERIOD,
	);
	timer.scheduleFunction(
		(_arg, time) => {
			if (_DMT_GEN !== generation) return undefined;
			try {
				tick();
			} catch (error) {
				log_fn(`fog_of_war tick error: ${tostring(error)}`);
			}
			return time + FOW_PERIOD;
		},
		undefined,
		timer.getTime() + FOW_OFFSET,
	);
}
