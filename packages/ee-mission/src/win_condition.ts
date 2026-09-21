/** @noSelfInFile */
/*
-- win_condition.lua
-- Inspired by:
--   aphavoc/source/entity/special/force/fc_msgs.c  response_to_check_campaign_objectives
--                                                   (the LIVE, shipped win check — lines 144-311)
--   aphavoc/source/ai/highlevl/setup.c             create_force_campaign_objectives (5 per side)
--   aphavoc/source/entity/mobile/aircraft/helicop/hc_dstry.c  helicopter-kill win trigger
--   aphavoc/source/entity/special/force/force.c    add_mobile_to_force_losses_stats (kill ledger)
--
-- Implements the THREE real end conditions of shipped EECH (spec 02 F26-F28 / spec 01 F13).
-- The Razorworks campaign_criteria evaluator in fc_updt.c is DEAD CODE (its whole body is
-- commented out); the community build ends a campaign purely event-driven, when a keysite is
-- captured/destroyed or a helicopter is killed, via response_to_check_campaign_objectives. A side
-- wins if ANY of:
--   (a) OBJECTIVES  — it OWNS every keysite in its campaign-objective set (troop-insertion
--                     targets must be owned; eech fc_msgs.c:180-211). See keysite.designate_objectives.
--   (b) NO USABLE AIRBASE — the enemy has no alive+in-use keysite with air_force_capacity != NONE
--                     (eech fc_msgs.c:222-249). In the port every keysite is an airbase, so this is
--                     "enemy owns no keysite at efficiency >= minimum" (usable state, KEYSITE-F11).
--   (c) NO GUNSHIPS — the enemy has no flyable player-controllable combat helicopter left
--                     (eech fc_msgs.c:255-295).
-- The invented 4-hour time limit and balance-of-power/captured-sectors criteria of the old port
-- (which modelled the DEAD fc_updt.c system) are REMOVED — EECH has no time-based end.
*/
import * as cs from "./campaign_state";
import * as keysite from "./keysite";
import * as persist from "./persist";
import * as pilots from "./pilots";
import * as supply from "./supply";
import type { Side } from "./campaign_types";

type LogFunction = (this: void, message: string) => void;

const S = cs.S;
const SIDES: Side[] = [coalition.side.BLUE, coalition.side.RED];
const CAMPAIGN_END_MESSAGE_SECONDS = 120;

function finish(winner: Side, reason: string, logFn: LogFunction): void {
	S.game_over = true;
	S.winner = winner;
	let blueOwned = 0;
	let redOwned = 0;
	for (const [, owner] of pairs(S.base_owner)) {
		if (owner === coalition.side.BLUE) blueOwned++;
		else if (owner === coalition.side.RED) redOwned++;
	}
	const message = string.format(
		"══════════ CAMPAIGN OVER ══════════\n%s VICTORY — %s\nBases: BLUE %d  RED %d   |   Strength: BLUE %d%%  RED %d%%",
		cs.SIDE_NAME[winner] ?? "?",
		reason,
		blueOwned,
		redOwned,
		S.strength[coalition.side.BLUE],
		S.strength[coalition.side.RED],
	);
	logFn(message);
	trigger.action.outText(message, CAMPAIGN_END_MESSAGE_SECONDS);
	cs.dbg(
		"win",
		"GAME OVER: %s wins (%s) — bases BLUE=%d RED=%d, strength BLUE=%d RED=%d",
		cs.SIDE_NAME[winner] ?? "?",
		reason,
		blueOwned,
		redOwned,
		S.strength[coalition.side.BLUE],
		S.strength[coalition.side.RED],
	);

	// WAVE 2 persistence: checkpoint the decided campaign so restarts preserve game_over/winner.
	pcall(() => persist.save(logFn));
	// PILOT-F14 / play_md.c:1062: every participating pilot receives the campaign medal.
	pcall(() => pilots.award_campaign_medals(winner, logFn));
}

// fc_msgs.c:180-211: every objective keysite must be owned by its force.
function holdsAllObjectives(side: Side): boolean {
	const objectives: string[] | undefined = S.objectives?.[side];
	if (objectives === undefined || objectives.length === 0) return false;
	for (const baseName of objectives) {
		if (S.base_owner[baseName] !== side) return false;
	}
	return true;
}

// fc_msgs.c:222-249: any enemy keysite alive and in use with air_force_capacity != NONE.
function hasUsableAirbase(side: Side): boolean {
	for (const [baseName, owner] of pairs(S.base_owner)) {
		if (
			owner === side &&
			cs.base_is_active(baseName) &&
			keysite.efficiency(baseName) >= cs.MINIMUM_EFFICIENCY
		) {
			return true;
		}
	}
	return false;
}

// fc_msgs.c:255-295 walks the enemy live-air registry for a surviving player-controllable combat
// helicopter. The port also counts reserves and queued regeneration because aircraft are spawned on
// demand rather than all being live at OOB time.
function liveCombatHelicopters(side: Side): number {
	const [ok, groups] = pcall(() =>
		coalition.getGroups(side, Group.Category.HELICOPTER),
	);
	if (!ok || groups === undefined) return 0;
	let count = 0;
	for (const group of groups) {
		if (group !== undefined && group.isExist()) {
			const units = group.getUnits();
			if (units !== undefined) {
				for (const unit of units) {
					if (unit !== undefined && unit.isExist()) {
						const description = unit.getDesc();
						if (description?.attributes?.["Attack helicopters"] === true) {
							count++;
							break;
						}
					}
				}
			}
		}
		if (count > 0) break;
	}
	return count;
}

function hasCombatHelicopterCapability(side: Side): boolean {
	if (liveCombatHelicopters(side) > 0) return true;
	if (supply.reserve_side(side, "heli") > 0) return true;
	const queue = S.regen_queue?.[side]?.heli;
	return queue !== undefined && queue.length > 0;
}

// ENTITY_MESSAGE_CHECK_CAMPAIGN_OBJECTIVES fan-out (fc_msgs.c F29).
export function check_win(logFn: LogFunction = () => undefined): void {
	if (S.game_over) return;
	cs.recalc_strength();

	for (const side of SIDES) {
		const enemy = cs.ENEMY[side];
		const objectives: string[] | undefined = S.objectives?.[side];
		let held = 0;
		if (objectives !== undefined) {
			for (const baseName of objectives) {
				if (S.base_owner[baseName] === side) held++;
			}
		}
		let enemyUsable = 0;
		for (const [baseName, owner] of pairs(S.base_owner)) {
			if (
				owner === enemy &&
				cs.base_is_active(baseName) &&
				keysite.efficiency(baseName) >= cs.MINIMUM_EFFICIENCY
			) {
				enemyUsable++;
			}
		}
		cs.dbg(
			"win",
			"%s check: objectives %d/%d held, enemy(%s) usable-airbases=%d, enemy live-combat-helis=%d",
			cs.SIDE_NAME[side],
			held,
			objectives?.length ?? 0,
			cs.SIDE_NAME[enemy],
			enemyUsable,
			liveCombatHelicopters(enemy),
		);

		if (holdsAllObjectives(side)) {
			finish(side, "all objective keysites captured", logFn);
			return;
		}
		if (!hasUsableAirbase(enemy)) {
			finish(side, `${cs.SIDE_NAME[enemy]} has no usable airbase`, logFn);
			return;
		}
		if (!hasCombatHelicopterCapability(enemy)) {
			finish(
				side,
				`${cs.SIDE_NAME[enemy]} combat helicopters eliminated`,
				logFn,
			);
			return;
		}
	}
}

export function make_kill_handler(
	logFn: LogFunction = () => undefined,
): DcsEventHandler {
	return {
		onEvent(event: DcsEvent): void {
			if (event.id !== world.event.S_EVENT_KILL || event.target === undefined)
				return;
			const target = event.target;
			let killerSide: Side | undefined;
			let victimSide: Side | undefined;
			pcall(() => {
				if (event.initiator?.getCoalition !== undefined) {
					const side = event.initiator.getCoalition?.();
					if (side === coalition.side.BLUE || side === coalition.side.RED)
						killerSide = side;
				}
			});
			pcall(() => {
				if (target.getCoalition !== undefined) {
					const side = target.getCoalition();
					if (side === coalition.side.BLUE || side === coalition.side.RED)
						victimSide = side;
				}
			});
			cs.stat_kill(killerSide, victimSide, cs.unit_category(target));
			check_win(logFn);
			pcall(() => pilots.on_kill(event));
		},
	};
}
