/** @noSelfInFile */
/*
-- persist.lua
-- EECH source:
--   aphavoc/source/session/session.c   pack_session / unpack_session — the campaign save/restore
--                                       root: elapsed_time, per-FORCE data, keysite ownership/strength,
--                                       reserve hardware, regen queues, and the mobile OOB are packed to
--                                       a save block and restored on load (SESSION-F15/F16/F17).
--   aphavoc/source/entity/special/force/force.c    force reserve hardware (restored, not respawned).
--   aphavoc/source/entity/special/keysite/keysite.c keysite side/strength/supply (restored).
--
-- WHAT THIS IS: the port's pack_session analog. EECH's process is a single monolithic entity-tree
-- serialize; the DCS port cannot serialize live DCS object handles (Group/StaticObject/scenery are
-- engine userdata that do not survive a process restart), so it saves a PROJECTION of the campaign
-- state singleton S — the subset that is either pure data or reconstructible — and RESPAWNS the mobile
-- OOB from position/count SUMMARIES on restore. Air-defence rings, firing points, patrols, installations
-- and the airbase-asset scenery are re-seeded FRESH by their own init() at boot (exactly as at-boot),
-- then overlaid with saved health; in-flight sorties are NOT restored (they RTB into the void of the old
-- process — EECH likewise does not resurrect airborne missions verbatim, it repacks the task tree which
-- the port drops; unassigned demand regenerates within one generator cycle).
--
-- TRANSPORT: the DCS Studio native bridge (dcs_studio.*), which the mission scripting env can reach and
-- which survives sanitizeModule (CLAUDE.md guardrail: NO os/io/lfs). dcs_studio.file is WRITE-ONLY
-- (write_text/write_json/write_csv/dump — no read fn), so the round-trippable store is dcs_studio.sqlite:
-- one row per slot holding a versioned, self-contained Lua-literal blob produced by the pure-Lua
-- serializer below (chosen over the bridge's JSON so integer coalition.side keys and mixed key types
-- round-trip exactly — JSON would stringify [2]=BLUE).
--
-- RE-INJECTION vs RESTART: a same-process hot re-inject is UNAFFECTED — restore only fires when
-- config.persistence.enabled is true (default FALSE), so all current dev workflows keep working exactly
-- as before. Enable it (DMT_CONFIG.persistence.enabled=true) for a dedicated-server deployment where the
-- campaign must survive a DCS_server.exe restart. See README "Persistence".
*/
import * as cs from "./campaign_state";
import type {
	CampaignState,
	KeysiteRecord,
	RegenEntry,
	Side,
	WorldPoint,
} from "./campaign_types";
import * as config from "./config";
import { BLUE, RED } from "./sides";

const S = cs.S;
const SAVE_VERSION = 1;
type LogFunction = (this: void, message: string) => void;
interface Database {
	exec(this: Database, sql: string, parameters?: (string | number)[]): unknown;
	query(
		this: Database,
		sql: string,
		parameters?: (string | number)[],
	): { blob?: unknown; version?: unknown; saved_t?: unknown }[];
	close(this: Database): void;
}
export interface Bridge {
	sqlite: {
		open(
			this: void,
			path: string,
		): LuaMultiReturn<[Database | undefined, string | undefined]>;
	};
}
declare global {
	/** Injected by DCS Studio when present; see `bridge()` below. */
	var dcs_studio: Bridge | undefined;
}

// Optional native bridge stays outside sanitized os/io/lfs.
function bridge(): Bridge | undefined {
	return _G.dcs_studio;
}
let _warned_no_bridge = false;
function no_bridge(): boolean {
	if (bridge()?.sqlite) return false;
	if (!_warned_no_bridge) {
		_warned_no_bridge = true;
		env.info(
			"[dmt:persist] dcs_studio bridge (sqlite) NOT reachable from the mission env — persistence DISABLED for this run (no save/restore). Campaign continues normally.",
		);
	}
	return true;
}
export function enabled(): boolean {
	return config.C.persistence.enabled === true;
}
function slot(): string {
	const s = config.C.persistence.slot;
	return s.length > 0 ? s : "default";
}
function db_path(): string {
	const p = config.C.persistence.db_path;
	return p.length > 0 ? p : "dmt_campaign.sqlite";
}
const DEFAULT_AUTOSAVE_PERIOD_SECONDS = 300;
const IEEE_754_EXACT_INTEGER_LIMIT = 2 ** 53;
function autosave_period(): number {
	const n = config.C.persistence.autosave_period;
	return n > 0 ? n : DEFAULT_AUTOSAVE_PERIOD_SECONDS;
}
function ser_num(v: number): string {
	if (Number.isNaN(v) || v === math.huge || v === -math.huge) return "0";
	if (v === math.floor(v) && math.abs(v) < IEEE_754_EXACT_INTEGER_LIMIT)
		return string.format("%d", v);
	return string.format("%.17g", v);
}
function is_table(v: unknown): v is Record<string | number, unknown> {
	return type(v) === "table";
}
export function _ser(v: unknown): string {
	if (typeof v === "number") return ser_num(v);
	if (typeof v === "boolean") return v ? "true" : "false";
	if (typeof v === "string") return string.format("%q", v);
	if (is_table(v)) {
		const parts: string[] = [];
		for (const [k, val] of pairs(v)) {
			if (
				typeof val === "number" ||
				typeof val === "boolean" ||
				typeof val === "string" ||
				is_table(val)
			) {
				const ks =
					typeof k === "number"
						? "[" + ser_num(k) + "]"
						: typeof k === "string"
							? "[" + string.format("%q", k) + "]"
							: undefined;
				if (ks !== undefined) parts.push(ks + "=" + _ser(val));
			}
		}
		return "{" + parts.join(",") + "}";
	}
	return "nil";
}
export function _deser(
	str: string,
): LuaMultiReturn<[unknown, string | undefined]> {
	if (typeof loadstring !== "function")
		return $multi(undefined, "no loadstring/load in this env");
	const [chunk] = loadstring("return " + str);
	if (!chunk) return $multi(undefined, "parse error");
	if (typeof setfenv === "function") pcall(() => setfenv(chunk, {}));
	const [ok, val] = pcall(chunk);
	if (!ok) return $multi(undefined, tostring(val));
	return $multi(val, undefined);
}
function leaf_count(t: unknown): number {
	if (!is_table(t)) return 1;
	let n = 0;
	for (const [, v] of pairs(t)) n += leaf_count(v);
	return n;
}
function key_count(t: unknown): number {
	let n = 0;
	if (is_table(t)) for (const [_] of pairs(t)) n++;
	return n;
}
export interface GroundSummary {
	name?: string;
	side: Side;
	kind: "primary" | "arty" | "sec";
	home_base: string;
	target_base?: string;
	n_alive: number;
	want?: number;
	lead: WorldPoint;
}
type SavedKeysite = Omit<KeysiteRecord, "scenery" | "dead"> & {
	scenery: { id: string | number; type: string; dead: boolean }[];
	dead: string[];
};
type SavedRegen = Record<
	number,
	Record<string, { base_name: string; aircraft_type: string; age: number }[]>
>;
interface SavedData
	extends Pick<
		CampaignState,
		| "game_over"
		| "winner"
		| "base_owner"
		| "base_health"
		| "base_pos"
		| "base_kind"
		| "base_efficiency"
		| "base_ammo"
		| "base_fuel"
		| "objectives"
		| "strength"
		| "base_ledger"
		| "production"
		| "fow"
		| "pilots"
		| "stats"
	> {
	start_elapsed: number;
	base_last_strike_age: Record<string, number>;
	regen_queue: SavedRegen;
	keysites: Record<string, SavedKeysite>;
	ground: GroundSummary[];
}
interface Envelope {
	version: number;
	saved_t: number;
	data: SavedData;
}
function group_summary(
	rec: { grp: Group; home_base: string; target_base?: string; want?: number },
	side: Side,
	kind: GroundSummary["kind"],
): GroundSummary | undefined {
	const grp = rec.grp;
	if (!cs.group_is_alive(grp)) return undefined;
	const n = grp.getUnits()?.length ?? 0;
	if (n <= 0) return undefined;
	const u = grp.getUnit(1);
	if (!u?.isExist()) return undefined;
	const p = u.getPosition().p;
	const [ok_name, gname] = pcall(() => grp.getName());
	return {
		name: ok_name ? gname : undefined,
		side,
		kind,
		home_base: rec.home_base,
		target_base: rec.target_base,
		n_alive: n,
		want: rec.want,
		lead: { x: p.x, z: p.z },
	};
}
function keysite_snapshot(rec: KeysiteRecord): SavedKeysite {
	// Version 1 intentionally retains the Lua ipairs behavior: only a contiguous numeric
	// sequence is saved, while string-keyed death flags are omitted by the original format.
	const dead: string[] = [];
	for (let index = 1; ; index++) {
		const name = rec.dead?.[index];
		if (name === undefined) break;
		dead.push(name);
	}
	return {
		kind: rec.kind,
		side: rec.side,
		pos: rec.pos,
		home_base: rec.home_base,
		health: rec.health,
		total: rec.total,
		alive: rec.alive,
		label: rec.label,
		producer: rec.producer,
		flags: rec.flags,
		assets: [...(rec.assets ?? [])],
		dead,
		scenery: (rec.scenery ?? []).map((row) => ({
			id: row.id,
			type: row.type,
			dead: row.dead === true,
		})),
	};
}
export function snapshot(): Envelope {
	const now = timer.getTime();
	const base_last_strike_age: Record<string, number> = {};
	for (const [name, t] of pairs(S.base_last_strike))
		base_last_strike_age[name] = now - t;
	const regen_queue: SavedRegen = {};
	for (const [side, byt] of pairs(S.regen_queue)) {
		const out: SavedRegen[number] = {};
		regen_queue[side] = out;
		for (const [atype, q] of pairs(byt))
			out[atype] = q.map((e) => ({
				base_name: e.base_name,
				aircraft_type: e.aircraft_type,
				age: now - e.enqueued,
			}));
	}
	const keysites: Record<string, SavedKeysite> = {};
	for (const [name, rec] of pairs(S.keysites))
		keysites[name] = keysite_snapshot(rec);
	const ground: GroundSummary[] = [];
	function add_reg(
		reg: Record<
			Side,
			Record<
				string,
				{ grp: Group; home_base: string; target_base?: string; want?: number }
			>
		>,
		kind: GroundSummary["kind"],
	): void {
		for (const [side, groups] of pairs(reg))
			for (const [, rec] of pairs(groups)) {
				const s = group_summary(rec, side, kind);
				if (s) ground.push(s);
			}
	}
	add_reg(S.ground_groups, "primary");
	add_reg(S.arty_groups, "arty");
	add_reg(S.sec_groups, "sec");
	return {
		version: SAVE_VERSION,
		saved_t: now,
		data: {
			start_elapsed: now - S.start_time,
			game_over: S.game_over,
			winner: S.winner,
			base_owner: S.base_owner,
			base_health: S.base_health,
			base_pos: S.base_pos,
			base_kind: S.base_kind,
			base_efficiency: S.base_efficiency,
			base_ammo: S.base_ammo,
			base_fuel: S.base_fuel,
			base_last_strike_age,
			objectives: S.objectives,
			strength: S.strength,
			base_ledger: S.base_ledger,
			production: S.production,
			regen_queue,
			fow: S.fow,
			pilots: S.pilots,
			stats: S.stats,
			keysites,
			ground,
		},
	};
}
const CREATE_TABLE =
	"CREATE TABLE IF NOT EXISTS campaign_save (slot TEXT PRIMARY KEY, version INTEGER, saved_t REAL, blob TEXT)";
export function save(log_fn: LogFunction = () => {}): boolean {
	if (!enabled() || no_bridge()) return false;
	const [ok_snap, envelope] = pcall(snapshot);
	if (!ok_snap) {
		log_fn("[persist] snapshot FAILED: " + tostring(envelope));
		cs.dbg("persist", "snapshot error: %s", tostring(envelope));
		return false;
	}
	const [ok_ser, blob] = pcall(_ser, envelope);
	if (!ok_ser) {
		log_fn("[persist] serialize FAILED: " + tostring(blob));
		cs.dbg("persist", "serialize error: %s", tostring(blob));
		return false;
	}
	const b = bridge();
	if (!b) return false;
	const [db, oerr] = b.sqlite.open(db_path());
	if (!db) {
		log_fn("[persist] sqlite.open FAILED: " + tostring(oerr));
		cs.dbg("persist", "sqlite.open error: %s", tostring(oerr));
		return false;
	}
	const [ok_w] = pcall(() => {
		db.exec(CREATE_TABLE);
		db.exec(
			"INSERT OR REPLACE INTO campaign_save (slot, version, saved_t, blob) VALUES (?, ?, ?, ?)",
			[slot(), SAVE_VERSION, envelope.saved_t, blob],
		);
	});
	pcall(() => db.close());
	if (!ok_w) {
		log_fn("[persist] sqlite write FAILED");
		cs.dbg("persist", "sqlite write error");
		return false;
	}
	const d = envelope.data;
	log_fn(
		string.format(
			"[persist] saved slot=%q (%d bytes, %d fields)",
			slot(),
			blob.length,
			leaf_count(d),
		),
	);
	cs.dbg(
		"persist",
		"SAVE slot=%s bytes=%d fields=%d | bases=%d keysites=%d ground=%d pilots=%d regen_q=%d",
		slot(),
		blob.length,
		leaf_count(d),
		key_count(d.base_owner),
		key_count(d.keysites),
		d.ground.length,
		key_count(d.pilots),
		key_count(d.regen_queue),
	);
	return true;
}
// Validate every persisted field at the native-bridge boundary before applying a typed overlay.
// The recursive schema keeps integer coalition keys in Lua tables, without JSON conversion.
type Schema =
	| "number"
	| "string"
	| "boolean"
	| { optional: Schema }
	| { values: Schema }
	| { fields: Record<string, Schema> }
	| { literal: string | number | boolean }
	| { oneOf: Schema[] };
const num: Schema = "number";
const str: Schema = "string";
const bool: Schema = "boolean";
function optional(s: Schema): Schema {
	return { optional: s };
}
function values(s: Schema): Schema {
	return { values: s };
}
function fields(s: Record<string, Schema>): Schema {
	return { fields: s };
}
function valid(v: unknown, schema: Schema): boolean {
	if (typeof schema === "string") return type(v) === schema;
	if ("oneOf" in schema) return schema.oneOf.some((member) => valid(v, member));
	if ("optional" in schema) return v === undefined || valid(v, schema.optional);
	if ("literal" in schema) return v === schema.literal;
	if (!is_table(v)) return false;
	if ("values" in schema) {
		for (const [, value] of pairs(v))
			if (!valid(value, schema.values)) return false;
		return true;
	}
	for (const [key, spec] of pairs(schema.fields))
		if (!valid(v[key], spec)) return false;
	return true;
}
const combatSide: Schema = {
	oneOf: [{ literal: BLUE }, { literal: RED }],
};
const point = fields({ x: num, z: num, y: optional(num) });
const ledger = fields({
	striker: num,
	escort: num,
	heli: num,
	recon: num,
	transport: num,
	vehicle: num,
});
const production = fields({
	ammo: num,
	fuel: num,
	ammo_rr: num,
	fuel_rr: num,
	ammo_earmark: num,
	fuel_earmark: num,
});
const pilot = fields({
	name: str,
	side: optional(combatSide),
	score: num,
	rank: num,
	kills: fields({
		air: num,
		ground: num,
		sea: num,
		fixed: num,
		fixed_wing: num,
		helicopter: num,
		air_defence: num,
		armour: num,
		artillery: num,
		friendly: num,
		total: num,
		deaths: optional(num),
	}),
	medals: values(num),
	sorties: num,
	deaths: num,
	missions_flown: num,
	air_medal_counter: num,
	sortie_score_start: num,
	sortie_damaged: bool,
	first_seen: num,
	last_brief_t: optional(num),
});
const stats = fields({
	kills: values(num),
	losses: values(num),
	sorties: num,
	tasks_created: num,
	tasks_completed: num,
	tasks_partial: num,
	tasks_failed: num,
});
const saved_site = fields({
	kind: str,
	side: optional(combatSide),
	pos: point,
	home_base: optional(str),
	health: num,
	total: optional(num),
	alive: optional(num),
	label: optional(str),
	producer: optional(fields({ ammo: num, fuel: num })),
	flags: fields({ ground_strike_target: bool, recon_target: bool }),
	assets: values(str),
	dead: values(str),
	scenery: values(fields({ id: { oneOf: [str, num] }, type: str, dead: bool })),
});
const saved_schema = fields({
	version: num,
	saved_t: num,
	data: fields({
		start_elapsed: num,
		game_over: bool,
		winner: optional(combatSide),
		base_owner: values(combatSide),
		base_health: values(num),
		base_pos: values(point),
		base_kind: values(str),
		base_efficiency: values(num),
		base_ammo: values(num),
		base_fuel: values(num),
		base_last_strike_age: values(num),
		objectives: values(values(str)),
		strength: values(num),
		base_ledger: values(ledger),
		production: values(production),
		fow: values(values(num)),
		pilots: values(pilot),
		stats: optional(values(stats)),
		regen_queue: values(
			values(values(fields({ base_name: str, aircraft_type: str, age: num }))),
		),
		keysites: values(saved_site),
		ground: values(
			fields({
				name: optional(str),
				side: combatSide,
				kind: str,
				home_base: str,
				target_base: optional(str),
				n_alive: num,
				want: optional(num),
				lead: point,
			}),
		),
	}),
});
function is_envelope(v: unknown): v is Envelope {
	return valid(v, saved_schema);
}
function load_envelope(log_fn: LogFunction): Envelope | undefined {
	if (no_bridge()) return undefined;
	const b = bridge();
	if (!b) return undefined;
	const [db, oerr] = b.sqlite.open(db_path());
	if (!db) {
		cs.dbg("persist", "restore sqlite.open error: %s", tostring(oerr));
		return undefined;
	}
	const [ok, rows] = pcall(() => {
		db.exec(CREATE_TABLE);
		return db.query(
			"SELECT blob, version, saved_t FROM campaign_save WHERE slot = ?",
			[slot()],
		);
	});
	pcall(() => db.close());
	const blob = ok ? rows[0]?.blob : undefined;
	if (typeof blob !== "string") {
		cs.dbg("persist", "restore: no save row for slot=%s", slot());
		return undefined;
	}
	const [envelope, derr] = _deser(blob);
	if (!is_envelope(envelope)) {
		log_fn(
			"[persist] restore: deserialize FAILED: " +
				tostring(derr ?? "invalid save fields"),
		);
		cs.dbg("persist", "restore deserialize error: %s", tostring(derr));
		return undefined;
	}
	if (envelope.version !== SAVE_VERSION) {
		cs.dbg(
			"persist",
			"restore: version mismatch (save=%s expected=%d) — ignoring",
			tostring(envelope.version),
			SAVE_VERSION,
		);
		return undefined;
	}
	return envelope;
}
let _restored = false;
let _data: SavedData | undefined;
export function was_restored(): boolean {
	return _restored;
}
export function restore_data(log_fn: LogFunction = () => {}): boolean {
	_restored = false;
	_data = undefined;
	if (!enabled()) {
		cs.dbg(
			"persist",
			"restore_data: persistence disabled (config) — fresh OOB",
		);
		return false;
	}
	const envelope = load_envelope(log_fn);
	if (!envelope) return false;
	const d = envelope.data;
	const now = timer.getTime();
	S.start_time = now - d.start_elapsed;
	S.game_over = d.game_over;
	S.winner = d.winner;
	S.base_owner = d.base_owner;
	S.base_health = d.base_health;
	S.base_pos = d.base_pos;
	S.base_kind = d.base_kind;
	S.base_efficiency = d.base_efficiency;
	S.base_ammo = d.base_ammo;
	S.base_fuel = d.base_fuel;
	S.objectives = d.objectives;
	S.strength = d.strength;
	S.base_ledger = d.base_ledger;
	S.production = d.production;
	S.fow = d.fow;
	S.pilots = d.pilots;
	if (d.stats !== undefined) S.stats = d.stats;
	S.base_last_strike = {};
	for (const [name, age] of pairs(d.base_last_strike_age))
		S.base_last_strike[name] = now - age;
	const rq: CampaignState["regen_queue"] = {
		[BLUE]: {},
		[RED]: {},
	};
	for (const side of [BLUE, RED]) {
		const byt = d.regen_queue[side];
		if (byt !== undefined) {
			const entries: Record<string, RegenEntry[]> = {};
			for (const [atype, q] of pairs(byt))
				entries[atype] = q.map((e) => ({
					base_name: e.base_name,
					aircraft_type: e.aircraft_type,
					enqueued: now - e.age,
				}));
			rq[side] = entries;
		}
	}
	S.regen_queue = rq;
	S.base_inflight = {};
	S.group_launch_base = {};
	_restored = true;
	_data = d;
	log_fn(
		string.format(
			"[persist] restore: applied slot=%q (saved %.0fs of campaign elapsed)",
			slot(),
			d.start_elapsed,
		),
	);
	cs.dbg(
		"persist",
		"RESTORE(data) slot=%s: bases=%d ledger-bases=%d regen_q=%d pilots=%d fow=%d strength B/R=%d/%d game_over=%s",
		slot(),
		key_count(d.base_owner),
		key_count(d.base_ledger),
		key_count(d.regen_queue),
		key_count(d.pilots),
		key_count(d.fow),
		S.strength[BLUE] ?? 0,
		S.strength[RED] ?? 0,
		tostring(S.game_over),
	);
	return true;
}
export function restore_world(log_fn: LogFunction = () => {}): void {
	if (!_restored || !_data) return;
	const d = _data;
	let n_ks = 0;
	let n_rekill = 0;
	for (const [name, snap] of pairs(d.keysites)) {
		const rec = S.keysites[name];
		if (!rec) {
			cs.dbg(
				"persist",
				"restore_world: saved keysite %s has no fresh record (placement drift) — skipped",
				name,
			);
			continue;
		}
		rec.health = snap.health;
		rec.alive = snap.alive;
		rec.total = snap.total ?? rec.total;
		rec.side = snap.side ?? rec.side;
		rec.dead = {};
		for (let index = 0; index < snap.dead.length; index++) {
			const dn = snap.dead[index];
			rec.dead[index + 1] = dn;
			const [ok_s, so] = pcall(StaticObject.getByName, dn);
			if (ok_s && so) {
				const [ok_d] = pcall(() => so.destroy());
				if (ok_d) n_rekill++;
			}
		}
		const by_id: Record<string, boolean> = {};
		for (const row of snap.scenery) by_id[tostring(row.id)] = row.dead === true;
		for (const row of rec.scenery ?? []) {
			const sd = by_id[tostring(row.id)];
			if (sd !== undefined) row.dead = sd;
		}
		n_ks++;
	}
	let n_resp = 0;
	const [ok_g, gnd] = pcall(
		() => require("./ground_forces") as typeof import("./ground_forces"),
	);
	if (ok_g) {
		for (const summ of d.ground) {
			const [ok] = pcall(gnd.respawn_saved, summ, log_fn);
			if (ok) n_resp++;
		}
	} else
		cs.dbg(
			"persist",
			"restore_world: ground_forces.respawn_saved unavailable — mobile OOB NOT restored",
		);
	log_fn(
		string.format(
			"[persist] restore(world): %d keysite(s) overlaid, %d dead static(s) re-killed, %d ground group(s) respawned",
			n_ks,
			n_rekill,
			n_resp,
		),
	);
	cs.dbg(
		"persist",
		"RESTORE(world): keysites=%d rekilled=%d ground_respawned=%d/%d",
		n_ks,
		n_rekill,
		n_resp,
		d.ground.length,
	);
}
export function schedule(log_fn: LogFunction = () => {}): void {
	if (!enabled()) {
		cs.dbg("persist", "autosave NOT scheduled (persistence disabled)");
		return;
	}
	if (no_bridge()) return;
	const period = autosave_period();
	const my_gen = _DMT_GEN;
	cs.dbg(
		"persist",
		"autosave scheduler REGISTERED period=%.0fs slot=%s db=%s",
		period,
		slot(),
		db_path(),
	);
	timer.scheduleFunction(
		(_, t) => {
			if (_DMT_GEN !== my_gen) return undefined;
			const [ok, err] = pcall(() => save(log_fn));
			if (!ok) {
				log_fn("[persist] autosave error: " + tostring(err));
				cs.dbg("persist", "autosave tick error: %s", tostring(err));
			}
			return t + period;
		},
		undefined,
		timer.getTime() + period,
	);
}
