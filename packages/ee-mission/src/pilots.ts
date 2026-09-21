/** @noSelfInFile */
/*
-- pilots.lua
-- EECH source:
--   aphavoc/source/entity/special/pilot/pi_funcs.c    pilot entity accessors (kills/rank/side)
--   aphavoc/source/entity/special/pilot/pilot.c        get_player_rank_from_points, high-score,
--                                                      join-announce, session pilot count
--   aphavoc/source/entity/system/en_types/en_plyr.h    entity_players (AI/LOCAL/REMOTE, :67-73)
--   aphavoc/source/ui_menu/player/player.c             promotion thresholds (:73-77),
--                                                      inc_player_log_kills classification (:912-977)
--   aphavoc/source/ui_menu/player/play_md.c            valour-medal criteria table (:218-260)
--   aphavoc/source/entity/mobile/mobile.c              credit_client_server_mobile_kill /
--                                                      calculate_task_points_for_kill (:281-484)
--   aphavoc/source/entity/mobile/aircraft/helicop/helicop.c  suitable_for_player (:1825-1966),
--                                                      notify_gunship_entity_mission_terminated
--
-- THE PILOT / PLAYER CAREER SUBSTRATE (Cluster 6, spec 10). EECH's PILOT entity + player_log are
-- NOT PORTED (DCS owns player slots, join/leave, side selection, occupancy — spec 10 §5). This
-- module is the port-side career record the campaign keeps ABOUT each human: per-player kills by
-- category, cumulative score (experience proxy), rank, valour medals, sorties and deaths, keyed by
-- getPlayerName. It is scaffolding: it activates fully only once flyable player slots exist (goals/03
-- P0 — coalition.addGroup cannot create human slots). With zero players every entry point is inert.
--
-- State lives in the campaign_state singleton (S.pilots) so a future persistence layer (goals/03 P1)
-- serializes it with the rest of the campaign. init() never clobbers an existing S.pilots (restore-safe).
--
-- PORTED IN WAVE 4 (this file):
--   * Player mission assignment (F19): a human binds an open player-flyable board task via the F-10
--     group menu (M._grp_request → task_board.assign_to_player); it leaves the AI pool and is registered
--     as the player's sortie so reaction/dedup/debrief treat it like an AI task.
--   * Per-sortie debrief loop (F9): M.on_debrief, fired from reaction's S_EVENT_LAND when a human lands
--     completing their task — mirrors notify_gunship_entity_mission_terminated (helicop.c:693-836).
--   * Air Medal (F11, 3 consecutive successes, play_md.c:1304-1359); Purple Heart (F13, damaged-but-
--     survived, play_md.c:1245-1296, tracked via S_EVENT_HIT → M.on_hit); Campaign medal at the win
--     declaration (F14, play_md.c:1062, M.award_campaign_medals from win_condition.finish).
--
-- DELIBERATELY NOT PORTED (noted, not reproduced):
--   * Flying-hours career track + aviator-wings flight-time medals (F12): the port keeps `sorties`
--     (mission count) but no flying-hours accrual, so the documented EECH ×1000 unit bug
--     (get_player_log_flying_hours uses TIME_1_HOUR = 3_600_000 ms, player.c:740, while
--     award_aviator_wings uses ONE_HOUR = 3600 s, play_md.c:1018 — spec 10 Open-Q1) is NOT
--     reproduced. If flying hours are ever added, divide seconds by 3600 (ONE_HOUR) everywhere.
--   * MP pilot entity replication, high-score table, planner locks (F1-F6,F18,F20-F22):
--     DCS-native or out of scope for this scaffolding.
*/
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import * as fow from "./fog_of_war";
import * as frontl from "./frontline";
import * as imap from "./imap";
import type { PilotRecord } from "./pilot_types";
import * as supply from "./supply";
import * as board from "./task_board";

const S = cs.S;
type LogFunction = (this: void, message: string) => void;
const METRES_PER_KILOMETRE = 1000;
const DEGREES_PER_TURN = 360;
const EVENT_MESSAGE_SECONDS = 15;
const SHORT_MESSAGE_SECONDS = 20;
const DETAIL_MESSAGE_SECONDS = 25;
const MENU_MESSAGE_SECONDS = 30;
const BRIEFING_DEBOUNCE_SECONDS = 10;
const MAX_BRIEF_TASKS = 3;
const MAX_REPORT_ROWS = 8;
const FULL_PERCENT = 100;
const RECOGNISED_CONTACT_THRESHOLD = fow.THRESHOLD_TASK;
const CRITICAL_TASK_PRIORITY_MULTIPLIER = 2; // assign.c:201-204
type GroupArgument = { gid: number; gname: string; side: Side };
type BriefTask = {
	type?: string;
	task_type?: string;
	target?: { base?: string; pos?: WorldPoint };
	target_base?: string;
	target_pos?: WorldPoint;
	critical?: boolean;
};
function info(msg: string): void {
	env.info(string.format("[ee-dcs] [pilots] %s", msg));
}
// player.c:73-77, rank names player.c:172-177. Public ranks remain one-based.
export const RANK = [
	{ name: "Lieutenant", points: 0 },
	{ name: "Captain", points: 7500 },
	{ name: "Major", points: 32000 },
	{ name: "Lt. Colonel", points: 120000 },
	{ name: "Colonel", points: 250000 },
];
// play_md.c:218-260; strictly greater than threshold (play_md.c:1212).
export const VALOUR = [
	{ name: "Flying Cross", points: 2600 },
	{ name: "Silver Star", points: 3200 },
	{ name: "Distinguished Service", points: 4000 },
	{ name: "Medal of Honour", points: 5000 },
];
// Existing category proxy for INT_TYPE_POINTS_VALUE (mobile.c:281-359).
export const KILL_POINTS: Record<string, number> = {
	fixed_wing: 100,
	helicopter: 100,
	air_defence: 80,
	armour: 60,
	artillery: 60,
	ground: 40,
	sea: 120,
	fixed: 50,
};
export const PLAYER_FLYABLE: Record<string, boolean> = {
	cas: true,
	bai: true,
	troop_insertion: true,
	bda: true,
};
export const AIR_MEDAL_STREAK = 3; // play_md.c:89
export const TEMPLATES: Record<string, string> = {
	cas: "CLOSE AIR SUPPORT: friendly ground forces are in contact near %s. Find and destroy the enemy armour and infantry in the engagement zone, then RTB.",
	bai: "BATTLEFIELD INTERDICTION: enemy ground forces are moving to reinforce %s. Interdict and destroy the column before it reaches the front line.",
	bda: "BATTLE DAMAGE ASSESSMENT: overfly %s and confirm the results of the preceding strike. Stay high, observe, and return to base.",
	troop_insertion:
		"AIR ASSAULT: %s has been suppressed below holding strength. Insert the assault troops onto the objective to capture it.",
	ground_strike:
		"GROUND STRIKE: destroy the high-value structures at %s to degrade its operational output.",
	oca_strike:
		"OCA STRIKE: hit the airbase at %s to suppress enemy air operations — crater the ramp and kill parked aircraft.",
	oca_sweep:
		"OCA SWEEP: sweep the airspace over %s ahead of the strike package and clear enemy fighters.",
	sead: "SEAD: suppress the enemy air-defence network protecting %s. Kill the radars and launchers screening the objective.",
	recon:
		"RECONNAISSANCE: overfly %s and reveal enemy dispositions to cue follow-on tasking.",
	heli_escort:
		"ESCORT: shepherd the friendly rotary package operating near %s and keep threats off it.",
	supply: "LOGISTICS: fly the resupply run into %s.",
};
function rank_from_points(pts: number): number {
	for (let i = RANK.length - 1; i >= 0; i--)
		if (pts >= RANK[i].points) return i + 1;
	return 1;
}
function get_or_create(name: string, side: Side | undefined): PilotRecord {
	let rec = S.pilots[name];
	if (!rec) {
		rec = {
			name,
			side,
			score: 0,
			rank: 1,
			kills: {
				air: 0,
				ground: 0,
				sea: 0,
				fixed: 0,
				fixed_wing: 0,
				helicopter: 0,
				air_defence: 0,
				armour: 0,
				artillery: 0,
				friendly: 0,
				total: 0,
			},
			medals: {},
			sorties: 0,
			deaths: 0,
			missions_flown: 0,
			air_medal_counter: 0,
			sortie_score_start: 0,
			sortie_damaged: false,
			first_seen: timer.getTime(),
		};
		S.pilots[name] = rec;
		info(
			string.format(
				"pilot record created: %s (%s)",
				name,
				side === undefined ? "?" : cs.SIDE_NAME[side],
			),
		);
		cs.dbg(
			"pilots",
			"record created: %s (%s)",
			name,
			side === undefined ? "?" : cs.SIDE_NAME[side],
		);
	}
	return rec;
}
type KillCategory = "air" | "ground" | "sea" | "fixed";
type KillSubcategory =
	| "fixed_wing"
	| "helicopter"
	| "air_defence"
	| "armour"
	| "artillery";
function classify_victim(
	victim: DcsObject,
): LuaMultiReturn<[KillCategory | undefined, KillSubcategory | undefined]> {
	const [ok, desc] = pcall(() => victim.getDesc());
	const a = (ok && desc ? desc.attributes : undefined) ?? {};
	if (a.Planes) return $multi("air", "fixed_wing");
	if (a.Helicopters) return $multi("air", "helicopter");
	if (
		a["Air Defence"] ||
		a.SAM ||
		a.AAA ||
		a["SR SAM"] ||
		a["MR SAM"] ||
		a["LR SAM"]
	)
		return $multi("ground", "air_defence");
	if (a.Ships) return $multi("sea", undefined);
	if (a.Buildings || a.Structures || a.Immobile)
		return $multi("fixed", undefined);
	if (a.Tanks || a["Armored vehicles"] || a.IFV || a.APC || a.MBT)
		return $multi("ground", "armour");
	if (a.Artillery) return $multi("ground", "artillery");
	if (a["Ground Units"] || a.Infantry) return $multi("ground", undefined);
	return $multi(undefined, undefined);
}
function award_after_score(rec: PilotRecord): void {
	const newr = rank_from_points(rec.score);
	if (newr > rec.rank) {
		rec.rank = newr;
		const msg = string.format(
			"%s promoted to %s (score %d)",
			rec.name,
			RANK[newr - 1].name,
			rec.score,
		);
		info(msg);
		pcall(trigger.action.outText, msg, EVENT_MESSAGE_SECONDS);
	}
	for (const m of VALOUR) {
		if (rec.score > m.points && rec.medals[m.name] === undefined) {
			rec.medals[m.name] = 1;
			const msg = string.format("%s awarded the %s", rec.name, m.name);
			info(msg);
			pcall(trigger.action.outText, msg, EVENT_MESSAGE_SECONDS);
		}
	}
}
function player_name(u: DcsObject | undefined): string | undefined {
	if (!u?.getPlayerName) return undefined;
	const [ok, name] = pcall(() => u.getPlayerName?.());
	return ok ? name : undefined;
}
function unit_side(u: DcsObject): Side | undefined {
	const [ok, side] = pcall(() => u.getCoalition?.());
	return ok && (side === coalition.side.BLUE || side === coalition.side.RED)
		? side
		: undefined;
}
export function on_kill(event: DcsEvent): void {
	if (event.id !== world.event.S_EVENT_KILL) return;
	const killer = event.initiator;
	const pname = player_name(killer);
	if (!killer || pname === undefined) return;
	const kside = unit_side(killer);
	const rec = get_or_create(pname, kside);
	const victim = event.target;
	if (!victim) return;
	const vside = unit_side(victim);
	const [cat, sub] = classify_victim(victim);
	if (!cat) return;
	if (vside !== undefined && vside === kside) {
		rec.kills.friendly++;
		info(string.format("%s FRIENDLY kill (no score)", pname));
		return;
	}
	rec.kills[cat]++;
	if (sub) rec.kills[sub]++;
	rec.kills.total++;
	const pts = KILL_POINTS[sub ?? cat] ?? 0;
	rec.score += pts;
	info(
		string.format(
			"%s kill: %s (+%d → score %d, %d total)",
			pname,
			sub ?? cat,
			pts,
			rec.score,
			rec.kills.total,
		),
	);
	cs.dbg(
		"pilots",
		"%s kill: %s +%d -> score %d rank=%s",
		pname,
		sub ?? cat,
		pts,
		rec.score,
		RANK[rec.rank - 1]?.name ?? "?",
	);
	award_after_score(rec);
}
export function on_death(event: DcsEvent): void {
	const pname = player_name(event.initiator);
	if (pname === undefined) return;
	const rec = S.pilots[pname];
	if (!rec) return;
	rec.deaths++;
	rec.kills.deaths = rec.deaths;
	rec.air_medal_counter = 0;
	rec.sortie_damaged = false;
	rec.sortie_score_start = rec.score;
	info(
		string.format(
			"%s DEATH recorded (deaths=%d, rank held at %s, no score penalty)",
			pname,
			rec.deaths,
			RANK[rec.rank - 1].name,
		),
	);
	cs.dbg(
		"pilots",
		"%s DEATH recorded: deaths=%d, air-medal streak reset, no score penalty",
		pname,
		rec.deaths,
	);
}
export function on_birth(event: DcsEvent): void {
	const u = event.initiator;
	const pname = player_name(u);
	if (!u || pname === undefined) return;
	const side = unit_side(u);
	const rec = get_or_create(pname, side);
	rec.sorties++;
	const [ok, g] = pcall(() => u.getGroup?.());
	const gid = ok && g ? g.getID() : undefined;
	const gname = ok && g ? g.getName() : undefined;
	if (gid !== undefined && gname !== undefined && side !== undefined)
		pcall(build_group_menu, gid, gname, side);
	const now = timer.getTime();
	if (
		rec.last_brief_t !== undefined &&
		now - rec.last_brief_t < BRIEFING_DEBOUNCE_SECONDS
	)
		return;
	rec.last_brief_t = now;
	if (side === undefined) return;
	const text = build_brief(rec, side);
	if (gid !== undefined && trigger.action.outTextForGroup) {
		const [sent] = pcall(
			trigger.action.outTextForGroup,
			gid,
			text,
			MENU_MESSAGE_SECONDS,
		);
		if (sent) {
			info(
				string.format("join brief sent to %s (group %s)", pname, tostring(gid)),
			);
			return;
		}
	}
	pcall(trigger.action.outText, text, MENU_MESSAGE_SECONDS);
	info(string.format("join brief (fallback outText) for %s", pname));
}
export function build_brief(rec: PilotRecord, side: Side): string {
	const enemy = cs.ENEMY[side];
	const lines = [
		string.format(
			"=== SITUATION BRIEF — %s (%s) ===",
			rec.name,
			RANK[rec.rank - 1]?.name ?? "?",
		),
	];
	lines.push(
		string.format(
			"Force strength: %s %d%%   %s %d%%",
			cs.SIDE_NAME[side] ?? "?",
			S.strength[side] ?? 0,
			cs.SIDE_NAME[enemy] ?? "?",
			S.strength[enemy] ?? 0,
		),
	);
	const [ok_h, heli] = pcall(supply.reserve_side, side, "heli");
	const [ok_s, striker] = pcall(supply.reserve_side, side, "striker");
	const [ok_e, escort] = pcall(supply.reserve_side, side, "escort");
	lines.push(
		string.format(
			"Your reserves: %d gunship, %d strike, %d escort",
			ok_h ? heli : 0,
			ok_s ? striker : 0,
			ok_e ? escort : 0,
		),
	);
	const [ok_f, fl] = pcall(frontl.get_frontline, side);
	lines.push(
		"Frontline (most forward): " + (ok_f ? (fl[0] ?? "none") : "none"),
	);
	const objs = S.objectives[side];
	lines.push(
		objs && objs.length > 0
			? "Objectives (capture): " + objs.join(", ")
			: "Objectives: (pending assignment)",
	);
	const [ok_m, miss] = pcall(get_player_missions, side);
	lines.push(
		string.format(
			"Open gunship missions: %d  (F10 > Campaign > Request Mission)",
			ok_m ? miss.length : 0,
		),
	);
	return lines.join("\n");
}
function nearest_own_base_pos(
	side: Side,
	pos: WorldPoint | undefined,
): WorldPoint | undefined {
	if (!pos) return undefined;
	let best: WorldPoint | undefined;
	let best_d2 = math.huge;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side) {
			const bpos = S.base_pos[name];
			if (bpos !== undefined) {
				const d2 = cs.dist2d(pos.x, pos.z, bpos.x, bpos.z) ** 2;
				if (d2 < best_d2) {
					best_d2 = d2;
					best = bpos;
				}
			}
		}
	}
	return best;
}
export function brief_for(
	task: BriefTask = {},
	origin_pos?: WorldPoint,
): string {
	const ttype = task.type ?? task.task_type ?? "recon";
	const tgt = task.target?.base ?? task.target_base ?? "the target area";
	const tpos = task.target?.pos ?? task.target_pos;
	const body = string.format(TEMPLATES[ttype] ?? "Mission vs %s.", tgt);
	let geo = "";
	if (origin_pos && tpos) {
		const rng =
			cs.dist2d(origin_pos.x, origin_pos.z, tpos.x, tpos.z) /
			METRES_PER_KILOMETRE;
		let brg = math.deg(
			cs.heading_to(origin_pos.x, origin_pos.z, tpos.x, tpos.z),
		);
		if (brg < 0) brg += DEGREES_PER_TURN;
		geo = string.format("  [Bearing %03.0f, %.0f km]", brg, rng);
	}
	return body + geo + (task.critical ? "  *PRIORITY*" : "");
}
export function get_player_missions(side: Side): {
	id: number;
	type: string;
	target: string;
	priority?: number;
	critical: boolean;
	text: string;
}[] {
	const out = S.board_tasks.filter(
		(t) =>
			t.state === "UNASSIGNED" && t.side === side && PLAYER_FLYABLE[t.type],
	);
	out.sort(
		(a, b) =>
			(b.priority ?? 1) * (b.critical ? CRITICAL_TASK_PRIORITY_MULTIPLIER : 1) -
			(a.priority ?? 1) * (a.critical ? CRITICAL_TASK_PRIORITY_MULTIPLIER : 1),
	);
	return out.slice(0, MAX_BRIEF_TASKS).map((t, i) => ({
		id: t.id,
		type: t.type,
		target: t.target?.base ?? "field",
		priority: t.priority,
		critical: t.critical ?? false,
		text: string.format(
			"%d. %s",
			i + 1,
			brief_for(t, nearest_own_base_pos(side, t.target?.pos)),
		),
	}));
}
function record_text(rec: PilotRecord): string {
	const medals: string[] = [];
	for (const [name] of pairs(rec.medals)) medals.push(name);
	return string.format(
		"%s  %s | score %d | kills %d (air %d, gnd %d, sea %d, fixed %d) | sorties %d | deaths %d%s",
		rec.name,
		RANK[rec.rank - 1]?.name ?? "?",
		rec.score,
		rec.kills.total,
		rec.kills.air,
		rec.kills.ground,
		rec.kills.sea,
		rec.kills.fixed,
		rec.sorties,
		rec.deaths,
		medals.length > 0 ? " | medals: " + medals.join(", ") : "",
	);
}
function out_side(side: Side, text: string, time: number): void {
	if (trigger.action.outTextForCoalition !== undefined) {
		const [ok] = pcall(trigger.action.outTextForCoalition, side, text, time);
		if (ok) return;
	}
	// Campaign reports may include coalition intelligence. Do not degrade to a
	// global message if DCS rejects the coalition-specific output call.
	info(string.format("coalition report suppressed for %s", cs.SIDE_NAME[side]));
}

function pct(value: number | undefined): number {
	return math.floor((value ?? 0) * FULL_PERCENT + 0.5);
}

function supply_percent(value: number | undefined): number {
	return math.floor(value ?? FULL_PERCENT);
}

function own_base_names(side: Side): string[] {
	return Object.keys(S.base_owner)
		.filter((name) => S.base_owner[name] === side)
		.sort();
}

function regen_count(side: Side): number {
	let total = 0;
	for (const queue of Object.values(S.regen_queue?.[side] ?? {}))
		total += queue?.length ?? 0;
	return total;
}

function task_target(task: {
	target?: { base?: string };
	target_base?: string;
}): string {
	return task.target?.base ?? task.target_base ?? "field";
}

/** Coalition-safe strategic summary: friendly state and only known enemy contacts. */
export function situation_report(side: Side): string {
	const enemy = cs.ENEMY[side];
	const ownBases = own_base_names(side);
	let knownEnemy = 0;
	for (const name of Object.keys(S.base_owner))
		if (
			S.base_owner[name] === enemy &&
			fow.get(name, side) >= RECOGNISED_CONTACT_THRESHOLD
		)
			knownEnemy++;
	const objectives = S.objectives[side] ?? [];
	const [frontOk, front] = pcall(frontl.get_frontline, side);
	return [
		"=== CAMPAIGN SITUATION ===",
		string.format(
			"%s strength: %d%%",
			cs.SIDE_NAME[side],
			S.strength[side] ?? 0,
		),
		string.format(
			"Controlled bases: %d | recognised enemy sites: %d",
			ownBases.length,
			knownEnemy,
		),
		"Forward base: " + (frontOk ? (front[0] ?? "none") : "unknown"),
		objectives.length > 0
			? "Objectives: " + objectives.join(", ")
			: "Objectives: pending assignment",
	].join("\n");
}

/** Own coalition task board. Queued and launched work are intentionally separate. */
export function tasking_report(side: Side): string {
	const queued = S.board_tasks
		.filter((task) => task.side === side && task.state === "UNASSIGNED")
		.sort((a, b) => b.priority - a.priority);
	const active: Array<[string, { task_type: string; target_base?: string }]> =
		[];
	for (const [name, task] of Object.entries(S.active_tasks))
		if (task.side === side && !name.startsWith("board:"))
			active.push([name, task]);
	const describeQueued = queued
		.slice(0, MAX_REPORT_ROWS)
		.map((task) =>
			string.format(
				"#%d %s → %s%s [P%d]",
				task.id,
				string.upper(task.type),
				task_target(task),
				task.critical ? " PRIORITY" : "",
				task.priority,
			),
		);
	const describeActive = active
		.slice(0, MAX_REPORT_ROWS)
		.map(([name, task]) =>
			string.format(
				"%s → %s (%s)",
				string.upper(task.task_type),
				task.target_base ?? "field",
				name,
			),
		);
	return [
		"=== AIR TASKING ===",
		string.format("Queued: %d | launched: %d", queued.length, active.length),
		"-- Queued --",
		...(describeQueued.length > 0 ? describeQueued : ["none"]),
		"-- Launched --",
		...(describeActive.length > 0 ? describeActive : ["none"]),
	].join("\n");
}

/** Friendly supply, production and regeneration; no enemy logistics are disclosed. */
export function logistics_report(side: Side): string {
	const production = S.production[side];
	const lines = [
		"=== LOGISTICS & REGENERATION ===",
		string.format(
			"Production bank: ammo %.0f (reserved %.0f) | fuel %.0f (reserved %.0f)",
			production?.ammo ?? 0,
			production?.ammo_earmark ?? 0,
			production?.fuel ?? 0,
			production?.fuel_earmark ?? 0,
		),
		string.format("Regeneration queue: %d replacement(s)", regen_count(side)),
		"-- Base supply --",
	];
	const bases = own_base_names(side)
		.sort(
			(a, b) =>
				(S.base_ammo[a] ?? 1) +
				(S.base_fuel[a] ?? 1) -
				((S.base_ammo[b] ?? 1) + (S.base_fuel[b] ?? 1)),
		)
		.slice(0, MAX_REPORT_ROWS);
	for (const name of bases) {
		const stock = S.base_ledger[name];
		lines.push(
			string.format(
				"%s: A%d F%d | H%d S%d E%d T%d | inflight %d",
				name,
				supply_percent(S.base_ammo[name]),
				supply_percent(S.base_fuel[name]),
				stock?.heli ?? 0,
				stock?.striker ?? 0,
				stock?.escort ?? 0,
				stock?.transport ?? 0,
				S.base_inflight[name] ?? 0,
			),
		);
	}
	if (bases.length === 0) lines.push("none");
	return lines.join("\n");
}

/** Enemy information is listed only when the coalition has current enough FOW. */
export function intelligence_report(side: Side): string {
	const enemy = cs.ENEMY[side];
	const contacts: Array<{
		name: string;
		fow: number;
		air: number;
		surface: number;
	}> = [];
	for (const name of Object.keys(S.base_owner)) {
		if (S.base_owner[name] !== enemy) continue;
		const visibility = fow.get(name, side);
		if (visibility < RECOGNISED_CONTACT_THRESHOLD) continue;
		const pos = S.base_pos[name];
		contacts.push({
			name,
			fow: visibility,
			air: imap.get(side, imap.AIR_DEFENCE, pos),
			surface: imap.get(side, imap.SURFACE_DEFENCE, pos),
		});
	}
	contacts.sort((a, b) => b.fow - a.fow);
	const lines = [
		"=== INTELLIGENCE SUMMARY ===",
		"Known enemy contacts only. Values decay without reconnaissance.",
		string.format("Recognised sites: %d", contacts.length),
	];
	for (const contact of contacts.slice(0, MAX_REPORT_ROWS))
		lines.push(
			string.format(
				"%s: confidence %d%% | air threat %d | ground threat %d",
				contact.name,
				pct(contact.fow),
				pct(contact.air),
				pct(contact.surface),
			),
		);
	if (contacts.length === 0)
		lines.push(
			"No recognised enemy sites. Fly reconnaissance to build the picture.",
		);
	return lines.join("\n");
}

export function _menu_situation(side: Side): void {
	out_side(side, situation_report(side), MENU_MESSAGE_SECONDS);
}

export function _menu_tasking(side: Side): void {
	out_side(side, tasking_report(side), DETAIL_MESSAGE_SECONDS);
}

export function _menu_logistics(side: Side): void {
	out_side(side, logistics_report(side), DETAIL_MESSAGE_SECONDS);
}

export function _menu_intelligence(side: Side): void {
	out_side(side, intelligence_report(side), DETAIL_MESSAGE_SECONDS);
}
export function _menu_request(side: Side): void {
	const [ok, miss] = pcall(get_player_missions, side);
	const ms = ok ? miss : [];
	if (ms.length === 0) {
		out_side(
			side,
			"Campaign: no open gunship missions right now.",
			SHORT_MESSAGE_SECONDS,
		);
		return;
	}
	const lines = [
		"-- Open gunship missions --",
		...ms.map((m) => m.text),
		"(To ACCEPT: from inside your aircraft use F10 > Campaign > Request Mission.)",
	];
	out_side(side, lines.join("\n"), DETAIL_MESSAGE_SECONDS);
}
export function _menu_record(side: Side): void {
	const roster: string[] = [];
	for (const [, rec] of pairs(S.pilots))
		if (rec.side === side) roster.push(record_text(rec));
	if (roster.length === 0) {
		out_side(
			side,
			"Campaign: no pilot records yet on this side.",
			SHORT_MESSAGE_SECONDS,
		);
		return;
	}
	roster.sort();
	roster.unshift("── Pilot records (this side) ──");
	out_side(side, roster.join("\n"), DETAIL_MESSAGE_SECONDS);
}
export function _menu_stats(side: Side): void {
	out_side(side, cs.stats_text(), MENU_MESSAGE_SECONDS);
}
function _out_group(
	gid: number | undefined,
	text: string,
	time = SHORT_MESSAGE_SECONDS,
): void {
	if (gid !== undefined && trigger.action.outTextForGroup) {
		const [ok] = pcall(trigger.action.outTextForGroup, gid, text, time);
		if (ok) return;
	}
	pcall(trigger.action.outText, text, time);
}
function group_player(
	gname: string,
): LuaMultiReturn<[Unit | undefined, string | undefined]> {
	const g = Group.getByName(gname);
	if (!g) return $multi(undefined, undefined);
	const [ok, u] = pcall(() => g.getUnit(1));
	if (!ok || !u) return $multi(undefined, undefined);
	return $multi(u, player_name(u));
}
export function build_group_menu(gid: number, gname: string, side: Side): void {
	if (!missionCommands) return;
	const arg = { gid, gname, side };
	pcall(() => {
		pcall(missionCommands.removeItemForGroup, gid, ["Campaign"]);
		const root = missionCommands.addSubMenuForGroup(gid, "Campaign");
		missionCommands.addCommandForGroup(
			gid,
			"Request Mission",
			root,
			_grp_request,
			arg,
		);
		missionCommands.addCommandForGroup(
			gid,
			"My Mission",
			root,
			_grp_mymission,
			arg,
		);
		missionCommands.addCommandForGroup(
			gid,
			"My Record",
			root,
			_grp_record,
			arg,
		);
	});
	cs.dbg(
		"pilots",
		"group F-10 menu built for %s (gid=%s, %s)",
		gname,
		tostring(gid),
		cs.SIDE_NAME[side] ?? "?",
	);
}
export function _grp_request(arg: GroupArgument): void {
	const { gid, gname, side } = arg;
	const cur = cs.get_task(gname);
	if (cur?.player) {
		_out_group(
			gid,
			"Campaign: you already have an active mission. RTB to complete it first.",
		);
		return;
	}
	let best: board.BoardTask | undefined;
	let best_p = 0;
	for (const t of S.board_tasks) {
		if (t.state === "UNASSIGNED" && t.side === side && PLAYER_FLYABLE[t.type]) {
			const p = (t.priority ?? 1) * (t.critical ? 2 : 1);
			if (!best || p > best_p) {
				best = t;
				best_p = p;
			}
		}
	}
	if (!best) {
		_out_group(
			gid,
			"Campaign: no gunship missions available right now - check back shortly.",
		);
		cs.dbg(
			"pilots",
			"player %s Request Mission: none available (side=%s)",
			gname,
			cs.SIDE_NAME[side] ?? "?",
		);
		return;
	}
	if (!board.assign_to_player(best, gname, gid)) {
		_out_group(gid, "Campaign: that mission was just taken - try again.");
		return;
	}
	const [u, pname] = group_player(gname);
	if (pname !== undefined) {
		const rec = get_or_create(pname, side);
		rec.sortie_score_start = rec.score;
		rec.sortie_damaged = false;
	}
	let origin: WorldPoint | undefined;
	if (u) {
		const [ok, p] = pcall(() => u.getPosition().p);
		if (ok) origin = p;
	}
	origin = origin ?? nearest_own_base_pos(side, best.target?.pos);
	_out_group(
		gid,
		"=== MISSION ASSIGNED ===\n" +
			brief_for(best, origin) +
			"\nReturn to base after completing the mission to log it.",
		MENU_MESSAGE_SECONDS,
	);
	cs.dbg(
		"pilots",
		"player %s ASSIGNED task #%d %s vs %s (left AI pool, no ledger/slot)",
		gname,
		best.id,
		best.type,
		best.target?.base ?? "field",
	);
}
export function _grp_mymission(arg: GroupArgument): void {
	const { gid, gname, side } = arg;
	const cur = cs.get_task(gname);
	if (!cur?.player) {
		_out_group(
			gid,
			"Campaign: you have no active mission. Use Request Mission to accept one.",
		);
		return;
	}
	const [u] = group_player(gname);
	let origin: WorldPoint | undefined;
	if (u) {
		const [ok, p] = pcall(() => u.getPosition().p);
		if (ok) origin = p;
	}
	origin = origin ?? nearest_own_base_pos(side, cur.target_pos);
	_out_group(
		gid,
		"=== CURRENT MISSION ===\n" + brief_for(cur, origin),
		DETAIL_MESSAGE_SECONDS,
	);
}
export function _grp_record(arg: GroupArgument): void {
	const [, pname] = group_player(arg.gname);
	const rec = pname === undefined ? undefined : S.pilots[pname];
	if (!rec) {
		_out_group(arg.gid, "Campaign: no record yet - fly a mission first.");
		return;
	}
	_out_group(arg.gid, record_text(rec), DETAIL_MESSAGE_SECONDS);
}
export function on_hit(event: DcsEvent): void {
	if (event.id !== world.event.S_EVENT_HIT) return;
	const tgt = event.target;
	const pname = player_name(tgt);
	if (!tgt || pname === undefined) return;
	const rec = S.pilots[pname] ?? get_or_create(pname, unit_side(tgt));
	if (!rec.sortie_damaged) {
		rec.sortie_damaged = true;
		cs.dbg(
			"pilots",
			"%s took damage this sortie (S_EVENT_HIT) -> Purple Heart eligible at debrief",
			pname,
		);
	}
}
export function on_debrief(
	u: DcsObject,
	task: BriefTask,
	assessment?: { result: string },
): void {
	const pname = player_name(u);
	if (pname === undefined) return;
	const rec = get_or_create(pname, unit_side(u));
	let mission_points = math.max(
		0,
		rec.score - (rec.sortie_score_start ?? rec.score),
	);
	const task_result = assessment?.result ?? "success";
	if (task_result === "failure") mission_points = 0;
	else if (task_result === "partial")
		mission_points = math.floor(mission_points / 4);
	rec.missions_flown++;
	award_after_score(rec);
	const awarded: string[] = [];
	if (task_result === "success") rec.air_medal_counter++;
	if (rec.air_medal_counter >= AIR_MEDAL_STREAK) {
		rec.medals["Air Medal"] = (rec.medals["Air Medal"] ?? 0) + 1;
		rec.air_medal_counter = 0;
		awarded.push("Air Medal");
	}
	const [ok, alive] = pcall(() => u.isExist());
	if (rec.sortie_damaged && ok && alive) {
		rec.medals["Purple Heart"] = (rec.medals["Purple Heart"] ?? 0) + 1;
		awarded.push("Purple Heart");
	}
	rec.sortie_damaged = false;
	rec.sortie_score_start = rec.score;
	let msg = string.format(
		"MISSION COMPLETE - %s: %s | +%d pts (score %d) | missions %d",
		pname,
		task.task_type ?? task.type ?? "sortie",
		mission_points,
		rec.score,
		rec.missions_flown,
	);
	if (awarded.length > 0) msg += " | AWARDED: " + awarded.join(", ");
	info(msg);
	cs.dbg(
		"pilots",
		"DEBRIEF %s: task=%s +%d pts score=%d missions=%d awards=[%s]",
		pname,
		tostring(task.task_type ?? task.type),
		mission_points,
		rec.score,
		rec.missions_flown,
		awarded.join(","),
	);
	const [okg, gid] = pcall(() => u.getGroup?.()?.getID());
	_out_group(okg ? gid : undefined, msg, SHORT_MESSAGE_SECONDS);
}
export function award_campaign_medals(
	winner: Side,
	log_fn: LogFunction = () => {},
): void {
	let n = 0;
	for (const [, rec] of pairs(S.pilots)) {
		if (rec.sorties > 0) {
			rec.medals.Campaign = (rec.medals.Campaign ?? 0) + 1;
			n++;
		}
	}
	if (n > 0) {
		log_fn(
			string.format(
				"pilots: campaign medal awarded to %d participating pilot(s)",
				n,
			),
		);
		cs.dbg(
			"pilots",
			"campaign medal awarded to %d participating pilot(s) (winner=%s)",
			n,
			cs.SIDE_NAME[winner] ?? "?",
		);
	}
}
export function build_menus(log_fn: LogFunction = () => {}): void {
	if (!missionCommands) {
		log_fn("pilots: missionCommands unavailable — F-10 menu skipped");
		return;
	}
	for (const side of [coalition.side.BLUE, coalition.side.RED] as const) {
		const [ok] = pcall(() => {
			const root = missionCommands.addSubMenuForCoalition(side, "Campaign");
			missionCommands.addCommandForCoalition(
				side,
				"Request Mission",
				root,
				_menu_request,
				side,
			);
			missionCommands.addCommandForCoalition(
				side,
				"My Record",
				root,
				_menu_record,
				side,
			);
			missionCommands.addCommandForCoalition(
				side,
				"Situation",
				root,
				_menu_situation,
				side,
			);
			missionCommands.addCommandForCoalition(
				side,
				"Air Tasking",
				root,
				_menu_tasking,
				side,
			);
			missionCommands.addCommandForCoalition(
				side,
				"Logistics & Regen",
				root,
				_menu_logistics,
				side,
			);
			missionCommands.addCommandForCoalition(
				side,
				"Intelligence",
				root,
				_menu_intelligence,
				side,
			);
			missionCommands.addCommandForCoalition(
				side,
				"Campaign Statistics",
				root,
				_menu_stats,
				side,
			);
		});
		if (!ok) {
			log_fn("pilots: F-10 menu build failed for side " + tostring(side));
			cs.dbg(
				"pilots",
				"F-10 menu build FAILED for side %s",
				cs.SIDE_NAME[side] ?? tostring(side),
			);
		}
	}
	log_fn(
		"pilots: F-10 'Campaign' menu registered (situation/tasking/logistics/intelligence)",
	);
	cs.dbg("pilots", "F-10 'Campaign' menu registered");
}
export function init(log_fn: LogFunction = () => {}): void {
	let n = 0;
	for (const [_] of pairs(S.pilots)) n++;
	log_fn(
		string.format(
			"pilots init — career substrate ready (%d existing record(s)); dormant until player slots exist",
			n,
		),
	);
	cs.dbg("pilots", "init: career substrate ready, %d existing record(s)", n);
}
