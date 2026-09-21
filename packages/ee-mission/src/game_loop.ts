/** @noSelfInFile */
/*
-- game_loop.lua
-- Inspired by:
--   aphavoc/source/ai/highlevl/highlevl.c   start_high_level_ai(): registers ALL campaign
--                                            AI functions into the update list with period + offset
--   aphavoc/source/update.c                 add_update_function: staggered periodic scheduler
--   aphavoc/source/update.h                 update_function_data_type: callback, sleep, offset
--   aphavoc/source/entity/special/session/ss_updt.c  session update: elapsed_time tick
--   aphavoc/source/entity/special/force/fc_updt.c    update_server: criteria evaluation every 5s
--
-- Orchestrator only — thin wiring layer, no campaign logic lives here.
-- Mirrors start_high_level_ai() which does nothing but register every task-generation
-- function into the update list; the logic is in each sub-system module.
--
-- Module dependency graph (mirrors EECH entity/AI split):
--   campaign_state  ← SESSION + FORCE data (no dependencies)
--   keysite         ← KEYSITE entity ops (requires campaign_state)
--   imap            ← influence maps (requires campaign_state)
--   fog_of_war      ← FOW decay (requires campaign_state)
--   frontline       ← frontline detection (requires campaign_state)
--   win_condition   ← fc_updt criteria + kill handler (requires campaign_state, keysite)
--   attack_waves    ← highlevl OCA/strike tasks (requires campaign_state, keysite)
--   ground_forces   ← highlevl advance/retreat tasks (requires campaign_state, keysite)
--   regen           ← dead-group regen FIFO (requires campaign_state, supply)
--   keysite_repair  ← ks_updt supply/repair tick (requires campaign_state)
--   cas_bai_sead    ← highlevl CAS/BAI/SEAD/OCA Sweep/Artillery (requires imap, fog_of_war, frontline)
--   troop           ← highlevl T.I. + patrol (requires campaign_state, imap, fog_of_war)
--   transfer        ← highlevl FW/HC transfer (requires campaign_state, imap, supply)
--   reaction        ← reactive AI on task-assign (requires campaign_state, supply)
--   game_loop       ← start_high_level_ai orchestrator (requires all above)
*/

import * as atk from "./attack_waves";
import * as base_defenses from "./base_defenses";
import * as sched from "./campaign_mode";
import * as cs from "./campaign_state";
import * as cas_m from "./cas_bai_sead";
import * as farps from "./farps";
import * as fow_m from "./fog_of_war";
import * as frontl from "./frontline";
import * as gnd from "./ground_forces";
import * as imap_m from "./imap";
import * as inst_m from "./installations";
import * as ks from "./keysite";
import * as kr_m from "./keysite_repair";
import * as ov from "./map_overlay";
import * as persist from "./persist";
import * as pilots_m from "./pilots";
import * as react_m from "./reaction";
import * as regen_m from "./regen";
import * as sup from "./supply";
import * as sf_m from "./supply_flight";
import * as board_m from "./task_board";
import * as xfer_m from "./transfer";
import * as troop_m from "./troop";
import * as wc from "./win_condition";
export const name = "game_loop";
export const version = "0.2.0";
const S = cs.S;
const CAPTURE_CHK = 60; // seconds; campaign ownership/win-condition cadence
const STATUS_PERIOD = 120; // seconds; status and strength refresh cadence
const CAPTURE_CHECK_INITIAL_DELAY = 90; // seconds; preserved Lua startup staggering
const SECONDS_PER_MINUTE = 60;
const PERCENT_SCALE = 100;
function info(msg: string): void {
	env.info(string.format("[ee-dcs] %s", msg));
}
function schedule_admin(): void {
	const my_gen = _DMT_GEN;
	cs.dbg(
		"loop",
		"admin scheduler REGISTERED: capture/win offset=90s period=%ds, status offset=%ds period=%ds",
		CAPTURE_CHK,
		STATUS_PERIOD,
		STATUS_PERIOD,
	);
	timer.scheduleFunction(
		(_, t) => {
			if (_DMT_GEN !== my_gen) return undefined;
			ks.try_capture(info);
			wc.check_win(info);
			return t + CAPTURE_CHK;
		},
		undefined,
		timer.getTime() + CAPTURE_CHECK_INITIAL_DELAY,
	);
	timer.scheduleFunction(
		(_, t) => {
			if (_DMT_GEN !== my_gen) return undefined;
			cs.recalc_strength();
			const elapsed = math.floor(
				(timer.getTime() - S.start_time) / SECONDS_PER_MINUTE,
			);
			const parts: string[] = [];
			for (const [n, o] of pairs(S.base_owner)) {
				const h = math.floor((S.base_health[n] ?? 1) * PERCENT_SCALE);
				parts.push(n + "=" + (cs.SIDE_NAME[o] ?? "?") + "(" + h + "%)");
			}
			parts.sort();
			info(
				string.format(
					"STATUS T+%dm BLUE=%d RED=%d | %s",
					elapsed,
					S.strength[coalition.side.BLUE],
					S.strength[coalition.side.RED],
					parts.join("  "),
				),
			);
			info(cs.stats_summary_line());
			return t + STATUS_PERIOD;
		},
		undefined,
		timer.getTime() + STATUS_PERIOD,
	);
}
export function start(): void {
	info("EECH-inspired campaign game loop v" + version + " starting");
	S.start_time = timer.getTime();
	ks.init_base_state(info);
	farps.init(info);
	cs.recalc_strength();
	sup.init(info);
	imap_m.init();
	fow_m.init();
	frontl.init_and_build();
	regen_m.init(info);
	kr_m.init(info);
	const restored = persist.restore_data(info);
	if (restored) {
		pcall(() => frontl.recompute());
		S.farp_active = {};
		pcall(() => farps.seed_activation(info));
	}
	if (!restored) gnd.init_oob(info);
	else
		cs.dbg(
			"loop",
			"restore active: skipping fresh ground OOB seed (mobile OOB respawns from save)",
		);
	inst_m.init(info);
	base_defenses.init(info);
	pilots_m.init(info);
	if (restored) persist.restore_world(info);
	info(
		string.format(
			"Campaign live — BLUE str=%d RED str=%d",
			S.strength[coalition.side.BLUE],
			S.strength[coalition.side.RED],
		),
	);
	let n_bases = 0;
	for (const [_] of pairs(S.base_owner)) n_bases++;
	cs.dbg(
		"loop",
		"Phase 1 init complete: %d bases known, generation=%d",
		n_bases,
		cs.GENERATION,
	);
	const handlers = _G.__dmt_handlers ?? [];
	_G.__dmt_handlers = handlers;
	function add_handler(h: DcsEventHandler): void {
		world.addEventHandler(h);
		handlers.push(h);
	}
	add_handler(wc.make_kill_handler(info));
	add_handler(regen_m.make_dead_handler(info));
	add_handler(sup.make_land_handler(info));
	add_handler(react_m.make_event_handler(info));
	cs.dbg(
		"loop",
		"Phase 2 complete: %d event handlers registered (kill/dead/land/reaction)",
		_G.__dmt_handlers.length,
	);
	const sched_roster: { label: string; offset: number }[] = [];
	function roster(label: string, offset: number): void {
		sched_roster.push({ label, offset });
	}
	board_m.schedule(info);
	sup.schedule_supply(info);
	kr_m.schedule_repair(info);
	sf_m.schedule_arrivals(info);
	regen_m.schedule_regen(info);
	fow_m.schedule_decay(info);
	imap_m.schedule_update(info);
	frontl.schedule_update(info);
	farps.schedule(info);
	atk.schedule_keysite_strikes(
		coalition.side.BLUE,
		sched.SCHED.keysite_strike.blue,
		info,
	);
	atk.schedule_keysite_strikes(
		coalition.side.RED,
		sched.SCHED.keysite_strike.red,
		info,
	);
	roster("keysite_strike/BLUE", sched.SCHED.keysite_strike.blue);
	roster("keysite_strike/RED", sched.SCHED.keysite_strike.red);
	atk.schedule_oca_strikes(
		coalition.side.BLUE,
		sched.SCHED.oca_strike.blue,
		info,
	);
	atk.schedule_oca_strikes(
		coalition.side.RED,
		sched.SCHED.oca_strike.red,
		info,
	);
	roster("oca_strike/BLUE", sched.SCHED.oca_strike.blue);
	roster("oca_strike/RED", sched.SCHED.oca_strike.red);
	gnd.schedule_ground(coalition.side.BLUE, sched.SCHED.ground.blue, info);
	gnd.schedule_ground(coalition.side.RED, sched.SCHED.ground.red, info);
	roster("ground/BLUE", sched.SCHED.ground.blue);
	roster("ground/RED", sched.SCHED.ground.red);
	troop_m.schedule_patrol(coalition.side.BLUE, sched.SCHED.patrol.blue, info);
	troop_m.schedule_patrol(coalition.side.RED, sched.SCHED.patrol.red, info);
	roster("patrol/BLUE", sched.SCHED.patrol.blue);
	roster("patrol/RED", sched.SCHED.patrol.red);
	cas_m.schedule_cas(coalition.side.BLUE, sched.SCHED.cas.blue, info);
	cas_m.schedule_cas(coalition.side.RED, sched.SCHED.cas.red, info);
	roster("cas/BLUE", sched.SCHED.cas.blue);
	roster("cas/RED", sched.SCHED.cas.red);
	cas_m.schedule_artillery(
		coalition.side.BLUE,
		sched.SCHED.artillery.blue,
		info,
	);
	cas_m.schedule_artillery(coalition.side.RED, sched.SCHED.artillery.red, info);
	roster("artillery/BLUE", sched.SCHED.artillery.blue);
	roster("artillery/RED", sched.SCHED.artillery.red);
	troop_m.schedule_troop_insertion(
		coalition.side.BLUE,
		sched.SCHED.troop_insertion.blue,
		info,
	);
	troop_m.schedule_troop_insertion(
		coalition.side.RED,
		sched.SCHED.troop_insertion.red,
		info,
	);
	roster("troop_insertion/BLUE", sched.SCHED.troop_insertion.blue);
	roster("troop_insertion/RED", sched.SCHED.troop_insertion.red);
	cas_m.schedule_sead(coalition.side.BLUE, sched.SCHED.sead.blue, info);
	cas_m.schedule_sead(coalition.side.RED, sched.SCHED.sead.red, info);
	roster("sead/BLUE", sched.SCHED.sead.blue);
	roster("sead/RED", sched.SCHED.sead.red);
	cas_m.schedule_bai(coalition.side.BLUE, sched.SCHED.bai.blue, info);
	cas_m.schedule_bai(coalition.side.RED, sched.SCHED.bai.red, info);
	roster("bai/BLUE", sched.SCHED.bai.blue);
	roster("bai/RED", sched.SCHED.bai.red);
	cas_m.schedule_oca_sweep(
		coalition.side.BLUE,
		sched.SCHED.oca_sweep.blue,
		info,
	);
	cas_m.schedule_oca_sweep(coalition.side.RED, sched.SCHED.oca_sweep.red, info);
	roster("oca_sweep/BLUE", sched.SCHED.oca_sweep.blue);
	roster("oca_sweep/RED", sched.SCHED.oca_sweep.red);
	xfer_m.schedule_hc_transfer(
		coalition.side.BLUE,
		sched.SCHED.hc_transfer.blue,
		info,
	);
	xfer_m.schedule_hc_transfer(
		coalition.side.RED,
		sched.SCHED.hc_transfer.red,
		info,
	);
	roster("hc_transfer/BLUE", sched.SCHED.hc_transfer.blue);
	roster("hc_transfer/RED", sched.SCHED.hc_transfer.red);
	xfer_m.schedule_fw_transfer(
		coalition.side.BLUE,
		sched.SCHED.fw_transfer.blue,
		info,
	);
	xfer_m.schedule_fw_transfer(
		coalition.side.RED,
		sched.SCHED.fw_transfer.red,
		info,
	);
	roster("fw_transfer/BLUE", sched.SCHED.fw_transfer.blue);
	roster("fw_transfer/RED", sched.SCHED.fw_transfer.red);
	inst_m.schedule_scenery_poll(info);
	schedule_admin();
	persist.schedule(info);
	ov.schedule_overlay(info);
	pilots_m.build_menus(info);
	for (const entry of sched_roster) {
		cs.dbg(
			"loop",
			"scheduler %-24s offset=%.1fs%s",
			entry.label,
			entry.offset,
			entry.offset <= 0 ? " <-- WARNING: DCS drops offset<=0!" : "",
		);
	}
	cs.dbg(
		"loop",
		"startup roster: %d schedulers registered (see individual subsystem tags for their own period/offset logs too)",
		sched_roster.length,
	);
	cs.dbg(
		"loop",
		"scheduler cadence MODE = %s (highlevl.c %s branch)",
		sched.mode,
		sched.mode === "skirmish" ? ":218-242" : ":246-268",
	);
	info("All campaign schedulers registered — EECH game loop active");
}
