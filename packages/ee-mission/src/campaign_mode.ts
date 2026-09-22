/** @noSelfInFile */
/*
-- campaign_mode.lua — scheduler cadence set selected by campaign mode (CAMPAIGN | SKIRMISH).
-- EECH source:
--   aphavoc/source/ai/highlevl/highlevl.c  start_high_level_ai (:181-287): registers every
--     create_*_tasks generator with a period + start_time. There are TWO tables — a SKIRMISH branch
--     (get_game_type()==GAME_TYPE_SKIRMISH, :218-242, faster periods) and the campaign branch
--     (the else, :246-268). A DCS session == campaign mode, which the port hardcoded across modules;
--     this module centralises BOTH so config.C.mode selects the cadence set.
--
-- WHAT LIVES HERE (and why it is not in config.lua): these are EECH-CITED ENGINE CONSTANTS (each value
-- cites its highlevl.c line), so per CLAUDE.md they stay in a module, not the scenario-data config. The
-- ONLY config knob is the selector `config.C.mode` ("campaign"|"skirmish"); a bad/absent value falls
-- back to CAMPAIGN here (defensive default — this module loads before config.load_and_validate runs).
--
-- SCHED[gen] = { period = seconds, blue = offset_s, red = offset_s }:
--   * period + `blue` (the port's BLUE-side start delay) trace to the cited EECH period/start_time.
--   * `red` is the port's per-side stagger of the single EECH generator into a BLUE and a RED pass
--     (EECH has one function per task; the port runs one per side). The stagger rule is a PORT
--     construct, applied IDENTICALLY in both modes so the two are structurally parallel:
--       - keysite_strike / oca_strike / ground → red = blue + floor(period/2)  (half-period offset)
--       - cas                                   → blue 5, red 30  (EECH start_time 0 bumped to 5: DCS
--                                                 silently drops a timer scheduled at getTime()+0)
--       - every other generator                 → red = blue + 30 (fixed 30 s stagger)
--   The CAMPAIGN column is BYTE-IDENTICAL to the port's prior hardcoded module periods + game_loop
--   offset expressions (verified value-by-value against the pre-change literals).
*/
import { C } from "./config";

export interface ScheduleEntry {
	period: number;
	blue: number;
	red: number;
}
export type ScheduleName =
	| "cas"
	| "patrol"
	| "ground"
	| "keysite_strike"
	| "artillery"
	| "troop_insertion"
	| "oca_sweep"
	| "hc_transfer"
	| "fw_transfer"
	| "sead"
	| "bai"
	| "oca_strike";
export type Schedule = Record<ScheduleName, ScheduleEntry>;
const MIN = 60;

export const CAMPAIGN: Schedule = {
	cas: { period: 15 * MIN, blue: 5, red: 30 },
	patrol: { period: 5 * MIN, blue: 5, red: 35 },
	ground: { period: 12 * MIN, blue: 12, red: 372 },
	keysite_strike: { period: 7.5 * MIN, blue: 15, red: 240 },
	artillery: { period: 15 * MIN, blue: 45, red: 75 },
	troop_insertion: { period: 2 * MIN, blue: 60, red: 90 },
	oca_sweep: { period: 30 * MIN, blue: 90, red: 120 },
	hc_transfer: { period: 7.5 * MIN, blue: 120, red: 150 },
	fw_transfer: { period: 15 * MIN, blue: 150, red: 180 },
	sead: { period: 12 * MIN, blue: 180, red: 210 },
	bai: { period: 20 * MIN, blue: 300, red: 330 },
	oca_strike: { period: 30 * MIN, blue: 390, red: 1290 },
};
export const SKIRMISH: Schedule = {
	cas: { period: 6 * MIN, blue: 5, red: 30 },
	sead: { period: 10 * MIN, blue: 2, red: 32 },
	ground: { period: 15 * MIN, blue: 12, red: 462 },
	artillery: { period: 12 * MIN, blue: 8, red: 38 },
	keysite_strike: { period: 10 * MIN, blue: 15, red: 315 },
	patrol: { period: 10 * MIN, blue: 5, red: 35 },
	fw_transfer: { period: 15 * MIN, blue: 34, red: 64 },
	troop_insertion: { period: 2 * MIN, blue: 60, red: 90 },
	bai: { period: 10 * MIN, blue: 90, red: 120 },
	hc_transfer: { period: 10 * MIN, blue: 180, red: 210 },
	oca_sweep: { period: 20 * MIN, blue: 240, red: 270 },
	oca_strike: { period: 30 * MIN, blue: 300, red: 1200 },
};
export const mode: "campaign" | "skirmish" =
	C.mode === "skirmish" ? "skirmish" : "campaign";
export const SCHED = mode === "skirmish" ? SKIRMISH : CAMPAIGN;
