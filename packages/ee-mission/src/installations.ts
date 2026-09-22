/** @noSelfInFile */
/*
-- installations.lua
-- EECH source: aphavoc/source/entity/special/keysite/keysite.h + keysite_database
--   Non-airbase keysites — bridges / depots / factories / radar / command — each with per-type
--   flags: oca_target, ground_strike_target, ship_strike_target, troop_insertion_target,
--   recon_target, requires_cap, requires_barcap, minimum_efficiency.
--
-- WHY THIS MODULE EXISTS: airbase-only keysites made create_keysite_strike_tasks (ground_strike_
-- target) and create_oca_strike_tasks (oca_target) hit the SAME set. EECH's keysite database has
-- many ground_strike-only keysites (depots, radars, bridges) that OCA never touches. These
-- installations restore that distinction: they are ground_strike_target + recon_target but NOT
-- oca_target / troop_insertion_target — so the ground-strike tasker and artillery hit them while
-- OCA-strike stays airfield-only.
--
-- TWO MODES:
--   • ZONE-AUTHORED (preferred, register_static_death spec): when the author placed keysite trigger
--     zones, the campaign REGISTERS the STATIC OBJECTS the author dropped inside each circle — it
--     SPAWNS NOTHING. Keysite health = alive registered assets / total registered assets; a struck
--     keysite destroys that fraction of its still-alive statics and drains toward 0 (neutralised /
--     capturable at < MINIMUM_EFFICIENCY, never removed). Terrain-safe: the author controls placement.
--   • AUTO (fallback, no zones): installations are placed PROCEDURALLY around each airbase (legacy).
--     Kept intact so an empty Caucasus mission still boots a scenario; this path still spawns.
*/
import * as cs from "./campaign_state";
import type {
	KeysiteFlags,
	KeysiteRecord,
	SceneryAssetRecord,
	Side,
	WorldPoint,
} from "./campaign_types";
import * as config from "./config";
import { BLUE, RED } from "./sides";
import * as zones from "./zones";

type LogFunction = (this: void, message: string) => void;
const S = cs.S;
const SPAWN_PHYSICAL = true;
const COUNTRY = config.C.countries;
const KINDS = config.C.statics.kinds;
const PRODUCER: Record<string, { ammo: number; fuel: number }> = {
	factory: { ammo: 1, fuel: 0 },
	refinery: { ammo: 0, fuel: 1 },
	port: { ammo: 0, fuel: 1 },
};
const FLAGS: Record<string, KeysiteFlags> = {
	factory: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: true,
		recon_target: false,
	},
	refinery: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: false,
		recon_target: true,
	},
	fuel: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: false,
		recon_target: true,
	},
	port: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: false,
		recon_target: false,
	},
	power: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: false,
		recon_target: true,
	},
	radar: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: false,
		recon_target: true,
	},
	depot: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: true,
		recon_target: true,
	},
	command: {
		requires_cap: false,
		requires_barcap: false,
		oca_target: false,
		ground_strike_target: true,
		troop_insertion_target: true,
		recon_target: true,
	},
};
export function flags_for_kind(kind: string): KeysiteFlags | undefined {
	return FLAGS[kind];
}
const ZONE_LABELS: Record<string, string> = {
	factory: "Munitions Factory",
	refinery: "Oil Refinery",
	port: "Port",
	power: "Power Station",
	radar: "Radar/EWR",
	depot: "Supply Depot",
	fuel: "Fuel Depot",
	command: "Command Post",
};
const BASE_LOADOUT = ["depot", "fuel", "radar"];
const REAR_LOADOUT = ["factory", "refinery"];
const REAR_OFFSET = 3200;
const KILL_DMG = 0.15;
const FRONT_DIST = config.C.theatre.front_dist;
const LOW_TARGET_THRESHOLD = 2;
// DCS adapter layout for turning EECH population templates into physical statics.
// These metre offsets are preserved from the Lua port and covered by smoke parity.
const BUILDING_GRID_SPACING_METRES = 45;
const GARRISON_OFFSET_METRES = 30;
const AAA_OFFSET_METRES = 50;
const SAM_OFFSET_METRES = 40;
const EWR_X_OFFSET_METRES = 50;
const EWR_Z_OFFSET_METRES = -30;
const INSTALLATION_RING_RADIUS_METRES = 550;
const PERCENT_SCALE = 100;
const INSTALLATION_NEUTRALISED_HEALTH = 0.1; // preserved Lua neutralisation threshold
const TARGET_WARNING_SECONDS = 30;
function nearest_enemy_dist(base: string, side: Side): number {
	const bp = S.base_pos[base];
	const enemy = cs.ENEMY[side];
	if (!bp || !enemy) return math.huge;
	let best = math.huge;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === enemy) {
			const ep = S.base_pos[name];
			if (ep !== undefined)
				best = math.min(best, cs.dist2d(bp.x, bp.z, ep.x, ep.z));
		}
	}
	return best;
}
function is_rear(base: string, side: Side): boolean {
	return nearest_enemy_dist(base, side) > FRONT_DIST;
}
function rear_offset_pos(base: string, side: Side): WorldPoint | undefined {
	const bp = S.base_pos[base];
	if (!bp) return undefined;
	const enemy = cs.ENEMY[side];
	let ex = bp.x;
	let ez = bp.z + 1;
	let best = math.huge;
	let found = false;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === enemy) {
			const ep = S.base_pos[name];
			if (ep !== undefined) {
				const d = cs.dist2d(bp.x, bp.z, ep.x, ep.z);
				if (d < best) {
					best = d;
					ex = ep.x;
					ez = ep.z;
					found = true;
				}
			}
		}
	}
	if (!found) return { x: bp.x + REAR_OFFSET, z: bp.z };
	const dx = bp.x - ex;
	const dz = bp.z - ez;
	const len = math.max(math.sqrt(dx * dx + dz * dz), 1);
	return {
		x: bp.x + (dx / len) * REAR_OFFSET,
		z: bp.z + (dz / len) * REAR_OFFSET,
	};
}
function spawn_installation(
	kname: string,
	kind: string,
	side: Side,
	pos: WorldPoint,
): "static" | "unit" | undefined {
	const spec = KINDS[kind];
	const cid = COUNTRY[side];
	if (!spec || cid === undefined || !SPAWN_PHYSICAL) return spec?.spawn;
	if (spec.spawn === "static") {
		pcall(coalition.addStaticObject, cid, {
			heading: 0,
			type: spec.type,
			shape_name: spec.shape,
			category: spec.cat,
			name: kname,
			x: pos.x,
			y: pos.z,
			dead: false,
		});
	} else if (spec.spawn === "unit") {
		const utype = spec.unit?.[side];
		if (utype !== undefined)
			pcall(coalition.addGroup, cid, Group.Category.GROUND, {
				name: kname,
				task: "Ground Nothing",
				units: [
					{
						name: kname + "-1",
						type: utype,
						x: pos.x,
						y: pos.z,
						heading: 0,
						skill: "Average",
					},
				],
				route: {
					points: [
						{
							x: pos.x,
							y: pos.z,
							type: "Turning Point",
							action: "Off Road",
							speed: 0,
							ETA: 0,
							ETA_locked: true,
						},
					],
				},
			});
	}
	return spec.spawn;
}
function pick_producer_bases(): Record<string, boolean> {
	const producer: Record<string, boolean> = {};
	for (const side of [BLUE, RED] as const) {
		const owned: string[] = [];
		let any_rear = false;
		for (const [base, owner] of pairs(S.base_owner))
			if (owner === side) owned.push(base);
		for (const base of owned)
			if (is_rear(base, side)) {
				producer[base] = true;
				any_rear = true;
			}
		if (!any_rear && owned.length > 0) {
			let best: string | undefined;
			let best_d = -1;
			for (const base of owned) {
				const d = nearest_enemy_dist(base, side);
				if (d !== math.huge && d > best_d) {
					best_d = d;
					best = base;
				}
			}
			producer[best ?? owned[0]] = true;
		}
	}
	return producer;
}
function recompute_health(rec: KeysiteRecord): void {
	if (!rec.assets && !rec.scenery) return;
	const total = rec.total ?? 0;
	let dead = 0;
	for (const nm of rec.assets ?? []) if (rec.dead?.[nm]) dead++;
	for (const s of rec.scenery ?? []) if (s.dead) dead++;
	rec.alive = math.max(0, total - dead);
	rec.health = total > 0 ? rec.alive / total : 0;
}
function nearest_owned_base(pos: WorldPoint, side: Side): string | undefined {
	let best: string | undefined;
	let bestd = math.huge;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side) {
			const bp = S.base_pos[name];
			if (bp !== undefined) {
				const d = cs.dist2d(pos.x, pos.z, bp.x, bp.z);
				if (d < bestd) {
					bestd = d;
					best = name;
				}
			}
		}
	}
	return best;
}
const PALETTE = config.C.statics.palette;
const GARRISON_UNITS = config.C.types.ground.garrison;
const AAA_UNIT = config.C.types.ground.aaa;
const SAM_UNITS = config.C.types.ground.sam;
const EWR_UNIT = config.C.types.ground.ewr;
const TEMPLATES: Record<
	string,
	{
		b: Record<string, number>;
		d: { garrison?: number; aaa?: number; sam?: number; ewr?: number };
	}
> = {
	factory: {
		b: { factory: 3, warehouse: 2, fueltank: 1, ammo: 1 },
		d: { garrison: 1, aaa: 2 },
	},
	refinery: {
		b: { fuel: 2, fueltank: 3, warehouse: 1 },
		d: { garrison: 1, aaa: 2 },
	},
	port: {
		b: { warehouse: 3, fueltank: 2, ammo: 1 },
		d: { garrison: 1, aaa: 2 },
	},
	depot: {
		b: { warehouse: 2, container: 3, ammo: 2, fueltank: 1 },
		d: { garrison: 1, aaa: 1 },
	},
	fuel: { b: { fuel: 2, fueltank: 3 }, d: { garrison: 1, aaa: 1 } },
	command: {
		b: { command: 1, bunker: 1, warehouse: 1 },
		d: { garrison: 1, aaa: 1, sam: 1 },
	},
	power: {
		b: { factory: 2, container: 2, fueltank: 1 },
		d: { garrison: 1, aaa: 1 },
	},
	radar: { b: { bunker: 1 }, d: { ewr: 1, sam: 1, aaa: 1 } },
};
function spawn_palette_static(
	name: string,
	token: string,
	side: Side,
	x: number,
	z: number,
): string | undefined {
	const p = PALETTE[token];
	const cid = COUNTRY[side];
	if (!p || cid === undefined) return undefined;
	pcall(coalition.addStaticObject, cid, {
		heading: 0,
		type: p[0],
		shape_name: p[1],
		category: p[2],
		name,
		x,
		y: z,
		dead: false,
	});
	return name;
}
function spawn_ground(
	name: string,
	side: Side,
	types: string[],
	pos: WorldPoint,
): void {
	const cid = COUNTRY[side];
	if (cid === undefined || types.length === 0) return;
	const units: UnitData[] = types.map((t, i) => {
		const ux = pos.x + (i % 3) * 30;
		const uz = pos.z + math.floor(i / 3) * 30;
		return {
			name: name + "-" + (i + 1),
			type: t,
			skill: "Average",
			x: ux,
			y: uz,
			heading: 0,
			alt: land.getHeight({ x: ux, y: uz }),
			alt_type: "BARO",
		};
	});
	pcall(coalition.addGroup, cid, Group.Category.GROUND, {
		name,
		task: "Ground Nothing",
		hidden: false,
		units,
		route: {
			points: [
				{
					type: "Turning Point",
					action: "Off Road",
					speed: 0,
					ETA: 0,
					ETA_locked: true,
					x: pos.x,
					y: pos.z,
					alt: land.getHeight({ x: pos.x, y: pos.z }),
					alt_type: "BARO",
					name: "Hold",
				},
			],
		},
	});
}
function spawn_keysite_template(
	kname: string,
	kind: string,
	side: Side,
	pos: WorldPoint,
): string[] {
	const tmpl = TEMPLATES[kind];
	if (!tmpl) return [];
	const cx = pos.x;
	const cz = pos.z;
	const names: string[] = [];
	const blds: string[] = [];
	for (const [token, n] of pairs(tmpl.b))
		for (let i = 0; i < n; i++) blds.push(token);
	const cols = math.max(1, math.ceil(math.sqrt(blds.length)));
	for (let i = 0; i < blds.length; i++) {
		const col = i % cols;
		const row = math.floor(i / cols);
		const cell = cs.snap_land(
			cx + (col - (cols - 1) / 2) * BUILDING_GRID_SPACING_METRES,
			cz + (row - (cols - 1) / 2) * BUILDING_GRID_SPACING_METRES,
			cx,
			cz,
		);
		const sn = spawn_palette_static(
			string.format("%s-b%d", kname, i + 1),
			blds[i],
			side,
			cell.x,
			cell.z,
		);
		if (sn) names.push(sn);
	}
	const d = tmpl.d;
	if (d.garrison !== undefined)
		spawn_ground(
			kname + "-def",
			side,
			GARRISON_UNITS[side] ?? [],
			cs.snap_land(
				cx + GARRISON_OFFSET_METRES,
				cz + GARRISON_OFFSET_METRES,
				cx,
				cz,
			),
		);
	if ((d.aaa ?? 0) > 0 && AAA_UNIT[side]) {
		const aaa: string[] = [];
		for (let i = 0; i < (d.aaa ?? 0); i++) aaa.push(AAA_UNIT[side]);
		spawn_ground(
			kname + "-aaa",
			side,
			aaa,
			cs.snap_land(cx - AAA_OFFSET_METRES, cz + AAA_OFFSET_METRES, cx, cz),
		);
	}
	if (d.sam !== undefined)
		spawn_ground(
			kname + "-sam",
			side,
			SAM_UNITS[side] ?? [],
			cs.snap_land(cx - SAM_OFFSET_METRES, cz - SAM_OFFSET_METRES, cx, cz),
		);
	if (d.ewr !== undefined && EWR_UNIT[side])
		spawn_ground(
			kname + "-ewr",
			side,
			[EWR_UNIT[side]],
			cs.snap_land(cx + EWR_X_OFFSET_METRES, cz + EWR_Z_OFFSET_METRES, cx, cz),
		);
	return names;
}
function init_from_zones(log_fn: LogFunction): void {
	let n = 0;
	let np = 0;
	let nassets = 0;
	let npending = 0;
	const warnings: string[] = [];
	for (const kz of zones.keysites()) {
		const kind = kz.type;
		if (kind === "airbase" || kind === "farp" || kz.side === undefined)
			continue;
		const pos = { x: kz.x, z: kz.z };
		let kname = string.format("KS-%s-%s", kind, kz.label);
		let uniq = kname;
		let k = 1;
		while (S.keysites[uniq]) {
			k++;
			uniq = kname + "-" + k;
		}
		kname = uniq;
		const assets = zones.statics_in_zone(kz.label);
		const scenery: SceneryAssetRecord[] = zones
			.scenery_in_zone(kz.label, zones.RESOURCE_SCENERY)
			.map((srow) => ({
				id: srow.id,
				type: srow.type,
				handle: srow.handle,
				dead: false,
			}));
		let nstatics = assets.length;
		const nscen = scenery.length;
		let ntotal = nstatics + nscen;
		let templated = false;
		if (nstatics === 0) {
			for (const sn of spawn_keysite_template(kname, kind, kz.side, pos))
				assets.push(sn);
			nstatics = assets.length;
			ntotal = assets.length + nscen;
			templated = true;
		}
		const pending = ntotal === 0 && !templated;
		const low_targets =
			!pending && !templated && ntotal <= LOW_TARGET_THRESHOLD;
		S.keysites[kname] = {
			kind,
			side: kz.side,
			pos,
			home_base: nearest_owned_base(pos, kz.side) ?? kz.label,
			assets,
			dead: {},
			scenery,
			total: ntotal,
			alive: ntotal,
			health: ntotal > 0 ? 1 : 0,
			pending,
			templated,
			low_targets,
			flags: FLAGS[kind] ?? { ground_strike_target: true, recon_target: true },
			label: ZONE_LABELS[kind] ?? kind,
			producer: PRODUCER[kind],
		};
		n++;
		nassets += ntotal;
		if (pending) npending++;
		else if (PRODUCER[kind]) np++;
		if (pending || low_targets)
			warnings.push(string.format("%s(%d)", kz.label, ntotal));
		log_fn(
			string.format(
				"  keysite %s [%s] registered %d placed statics + %d resource scenery%s",
				kname,
				cs.SIDE_NAME[kz.side] ?? "?",
				nstatics,
				nscen,
				pending ? " (PENDING — empty)" : low_targets ? " (LOW TARGETS)" : "",
			),
		);
	}
	log_fn(
		string.format(
			"installations from zones: %d keysites (%d producers, %d pending/empty), %d registered statics (author-placed — NO spawning)",
			n,
			np,
			npending,
			nassets,
		),
	);
	cs.dbg(
		"installs",
		"init_from_zones: %d keysites (%d producers, %d pending/empty), %d assets registered",
		n,
		np,
		npending,
		nassets,
	);
	if (warnings.length > 0) {
		const list = warnings.join(", ");
		log_fn(
			string.format(
				"WARNING: %d keysite(s) have no/low targets (<= %d assets) — place more statics/resource objects in these circles: %s",
				warnings.length,
				LOW_TARGET_THRESHOLD,
				list,
			),
		);
		pcall(
			trigger.action.outText,
			string.format(
				"⚠ CAMPAIGN: %d keysite(s) need targets (<= %d assets each).\nPlace static objects / resource scenery inside these zone circles:\n%s",
				warnings.length,
				LOW_TARGET_THRESHOLD,
				list,
			),
			TARGET_WARNING_SECONDS,
			false,
		);
	}
}
function notify_under_attack(name: string, log_fn?: LogFunction): void {
	const [ok, react] = pcall(
		() => require("./reaction") as typeof import("./reaction"),
	);
	if (ok) pcall(react.on_keysite_under_attack, name, log_fn);
}
export function register_static_death(
	static_name: string | undefined,
	log_fn?: LogFunction,
): string | undefined {
	if (static_name === undefined) return undefined;
	for (const [kname, rec] of pairs(S.keysites)) {
		if (rec.assets && rec.dead && !rec.dead[static_name]) {
			for (const nm of rec.assets) {
				if (nm !== static_name) continue;
				rec.dead[static_name] = true;
				recompute_health(rec);
				if (rec.kind === "airbase" && rec.home_base)
					notify_under_attack(rec.home_base, log_fn);
				log_fn?.(
					string.format(
						"keysite %s asset lost: %s (%d/%d alive, %.0f%%)",
						rec.label ?? kname,
						static_name,
						rec.alive,
						rec.total,
						rec.health * PERCENT_SCALE,
					),
				);
				cs.dbg(
					"installs",
					"%s asset lost: %s (%d/%d alive, %.0f%%)%s",
					kname,
					static_name,
					rec.alive,
					rec.total,
					rec.health * PERCENT_SCALE,
					rec.health <= INSTALLATION_NEUTRALISED_HEALTH
						? " -> NEUTRALISED"
						: "",
				);
				return kname;
			}
		}
	}
	return undefined;
}
export function init_static_death_handler(
	log_fn: LogFunction = () => {},
): void {
	if (_G.__dmt_static_death_handler) {
		pcall(world.removeEventHandler, _G.__dmt_static_death_handler);
		_G.__dmt_static_death_handler = undefined;
	}
	const h: DcsEventHandler = {
		onEvent(this: DcsEventHandler, event: DcsEvent): void {
			if (
				event.id !== world.event.S_EVENT_DEAD &&
				event.id !== world.event.S_EVENT_KILL
			)
				return;
			const obj =
				event.id === world.event.S_EVENT_KILL
					? (event.target ?? event.initiator)
					: event.initiator;
			if (!obj) return;
			const [ok, nm] = pcall(() => obj.getName());
			if (ok && nm !== undefined) register_static_death(nm, log_fn);
		},
	};
	world.addEventHandler(h);
	_G.__dmt_static_death_handler = h;
}
export function poll_scenery(log_fn: LogFunction = () => {}): void {
	for (const [kname, rec] of pairs(S.keysites)) {
		let dropped = 0;
		for (const s of rec.scenery ?? []) {
			if (!s.dead) {
				const [ok, life] = pcall(() => s.handle.getLife());
				if (!ok || life === undefined || life <= 1) {
					s.dead = true;
					dropped++;
				}
			}
		}
		if (dropped > 0) {
			recompute_health(rec);
			log_fn(
				string.format(
					"keysite %s scenery lost: %d destroyed (%d/%d alive, %.0f%%)",
					rec.label ?? kname,
					dropped,
					rec.alive ?? 0,
					rec.total ?? 0,
					rec.health * PERCENT_SCALE,
				),
			);
			cs.dbg(
				"installs",
				"%s scenery poll: %d dropped this pass (%d/%d alive, %.0f%%)",
				kname,
				dropped,
				rec.alive ?? 0,
				rec.total ?? 0,
				rec.health * PERCENT_SCALE,
			);
		}
	}
}
const SCENERY_POLL_PERIOD = 25;
export function schedule_scenery_poll(log_fn: LogFunction = () => {}): void {
	const my_gen = _DMT_GEN;
	cs.dbg(
		"installs",
		"scenery-poll scheduler REGISTERED offset=%.0fs period=%.0fs",
		SCENERY_POLL_PERIOD,
		SCENERY_POLL_PERIOD,
	);
	timer.scheduleFunction(
		(_, t) => {
			if (_DMT_GEN !== my_gen) return undefined;
			poll_scenery(log_fn);
			return t + SCENERY_POLL_PERIOD;
		},
		undefined,
		timer.getTime() + SCENERY_POLL_PERIOD,
	);
}
export function init(log_fn: LogFunction = () => {}): void {
	init_static_death_handler(log_fn);
	if (zones.has_keysite_zones()) {
		init_from_zones(log_fn);
		return;
	}
	S.keysites = {};
	const producer = pick_producer_bases();
	let n = 0;
	let np = 0;
	for (const [base, owner] of pairs(S.base_owner)) {
		if (owner !== BLUE && owner !== RED) continue;
		const rear = rear_offset_pos(base, owner);
		if (!rear) continue;
		const loadout = [...BASE_LOADOUT];
		if (producer[base]) for (const k of REAR_LOADOUT) loadout.push(k);
		const bc = S.base_pos[base];
		for (let i = 0; i < loadout.length; i++) {
			const kind = loadout[i];
			const ang = i * ((2 * math.pi) / loadout.length);
			const pos = cs.snap_land(
				rear.x + math.cos(ang) * INSTALLATION_RING_RADIUS_METRES,
				rear.z + math.sin(ang) * INSTALLATION_RING_RADIUS_METRES,
				bc?.x ?? rear.x,
				bc?.z ?? rear.z,
			);
			const kname = string.format("Inst-%s-%s", kind, base);
			const spawn_kind = spawn_installation(kname, kind, owner, pos);
			S.keysites[kname] = {
				home_base: base,
				kind,
				pos,
				health: 1,
				flags: FLAGS[kind],
				label: KINDS[kind].label,
				producer: PRODUCER[kind],
				spawn_kind,
			};
			n++;
			if (PRODUCER[kind]) np++;
		}
	}
	log_fn(
		string.format(
			"installations: %d non-airbase keysites placed (%d producers) [%s]",
			n,
			np,
			SPAWN_PHYSICAL ? "physical statics + EWR radar units" : "abstract points",
		),
	);
	cs.dbg(
		"installs",
		"init (auto/procedural path): %d keysites placed (%d producers)",
		n,
		np,
	);
}
export function production_rates(side: Side): LuaMultiReturn<[number, number]> {
	let ammo = 0;
	let fuel = 0;
	for (const [, rec] of pairs(S.keysites)) {
		const p = rec.producer;
		if (
			p &&
			!rec.pending &&
			rec.health > INSTALLATION_NEUTRALISED_HEALTH &&
			(rec.alive === undefined || rec.alive > 0) &&
			side_of(rec) === side
		) {
			ammo += p.ammo ?? 0;
			fuel += p.fuel ?? 0;
		}
	}
	return $multi(ammo, fuel);
}
export function side_of(rec: KeysiteRecord): Side | undefined {
	return (
		rec.side ??
		(rec.home_base === undefined ? undefined : S.base_owner[rec.home_base])
	);
}
export function nearest_producer(
	side: Side,
	commodity: "ammo" | "fuel",
	pos?: WorldPoint,
): { name: string; pos: WorldPoint } | undefined {
	let primary: { name: string; pos: WorldPoint } | undefined;
	let primary_d2 = math.huge;
	let nearest: { name: string; pos: WorldPoint } | undefined;
	let nearest_d2 = math.huge;
	for (const [kname, rec] of pairs(S.keysites)) {
		const p = rec.producer;
		if (
			p &&
			!rec.pending &&
			rec.health > INSTALLATION_NEUTRALISED_HEALTH &&
			(rec.alive === undefined || rec.alive > 0) &&
			side_of(rec) === side &&
			rec.pos
		) {
			const d2 = pos ? (pos.x - rec.pos.x) ** 2 + (pos.z - rec.pos.z) ** 2 : 0;
			if (d2 < nearest_d2) {
				nearest_d2 = d2;
				nearest = { name: kname, pos: rec.pos };
			}
			if ((p[commodity] ?? 0) > 0 && d2 < primary_d2) {
				primary_d2 = d2;
				primary = { name: kname, pos: rec.pos };
			}
		}
	}
	return primary ?? nearest;
}
export function strike_targets(attacker: Side): {
	name: string;
	pos: WorldPoint;
	health: number;
	kind: string;
	recon_target: boolean;
}[] {
	const enemy = cs.ENEMY[attacker];
	const out: {
		name: string;
		pos: WorldPoint;
		health: number;
		kind: string;
		recon_target: boolean;
	}[] = [];
	for (const [kname, rec] of pairs(S.keysites))
		if (
			rec.flags.ground_strike_target &&
			!rec.pending &&
			rec.health > INSTALLATION_NEUTRALISED_HEALTH &&
			side_of(rec) === enemy
		)
			out.push({
				name: kname,
				pos: rec.pos,
				health: rec.health,
				kind: rec.kind,
				recon_target: rec.flags.recon_target === true,
			});
	return out;
}
function owner_label(rec: KeysiteRecord): string {
	const side = side_of(rec);
	return side === undefined ? "?" : (cs.SIDE_NAME[side] ?? "?");
}
export function damage(
	kname: string,
	amount?: number,
	log_fn: LogFunction = () => {},
): number | undefined {
	const rec = S.keysites[kname];
	if (!rec) return undefined;
	notify_under_attack(kname, log_fn);
	if (rec.assets) {
		if ((rec.alive ?? 0) <= 0) return undefined;
		const before = rec.health;
		const want = math.min(
			math.ceil((amount ?? KILL_DMG) * (rec.total ?? 0)),
			rec.alive ?? 0,
		);
		let destroyed = 0;
		const dead = rec.dead ?? {};
		rec.dead = dead;
		for (const nm of rec.assets) {
			if (destroyed >= want) break;
			if (!dead[nm]) {
				const so = StaticObject.getByName(nm);
				if (so) pcall(() => so.destroy());
				dead[nm] = true;
				destroyed++;
			}
		}
		if (destroyed < want)
			for (const s of rec.scenery ?? []) {
				if (destroyed >= want) break;
				if (!s.dead) {
					pcall(() => s.handle.destroy());
					s.dead = true;
					destroyed++;
				}
			}
		recompute_health(rec);
		if (rec.health > INSTALLATION_NEUTRALISED_HEALTH) {
			log_fn(
				string.format(
					"keysite %s struck: %.0f%%->%.0f%% (%d/%d statics left)",
					rec.label ?? kname,
					before * PERCENT_SCALE,
					rec.health * PERCENT_SCALE,
					rec.alive,
					rec.total,
				),
			);
			cs.dbg(
				"installs",
				"%s damaged: %.0f%%->%.0f%% (%d assets destroyed this hit, %d/%d left)",
				kname,
				before * PERCENT_SCALE,
				rec.health * PERCENT_SCALE,
				destroyed,
				rec.alive,
				rec.total,
			);
		} else {
			log_fn(
				string.format(
					"keysite %s DESTROYED%s (%s) — %d/%d statics, capturable",
					rec.label ?? kname,
					rec.producer ? " — PRODUCER LOST, supply cut" : "",
					owner_label(rec),
					rec.alive,
					rec.total,
				),
			);
			cs.dbg(
				"installs",
				"%s NEUTRALISED (%.0f%%->%.0f%%)%s owner=%s",
				kname,
				before * PERCENT_SCALE,
				rec.health * PERCENT_SCALE,
				rec.producer ? " PRODUCER LOST" : "",
				owner_label(rec),
			);
		}
		return rec.health;
	}
	if (rec.health <= INSTALLATION_NEUTRALISED_HEALTH) return undefined;
	const before = rec.health;
	rec.health = math.max(0, rec.health - (amount ?? KILL_DMG));
	if (rec.health > INSTALLATION_NEUTRALISED_HEALTH) {
		log_fn(
			string.format(
				"installation struck: %s %.0f%%->%.0f%% (%s)",
				rec.label,
				before * PERCENT_SCALE,
				rec.health * PERCENT_SCALE,
				kname,
			),
		);
		cs.dbg(
			"installs",
			"%s (auto) damaged: %.0f%%->%.0f%%",
			kname,
			before * PERCENT_SCALE,
			rec.health * PERCENT_SCALE,
		);
	}
	if (rec.health <= INSTALLATION_NEUTRALISED_HEALTH) {
		log_fn(
			string.format(
				"installation DESTROYED: %s at %s%s (%s)",
				rec.label,
				rec.home_base,
				rec.producer ? " — PRODUCER LOST, supply cut" : "",
				owner_label(rec),
			),
		);
		cs.dbg(
			"installs",
			"%s (auto) NEUTRALISED at %s%s owner=%s",
			kname,
			rec.home_base,
			rec.producer ? " PRODUCER LOST" : "",
			owner_label(rec),
		);
		pcall(() => {
			if (rec.spawn_kind === "unit") Group.getByName(kname)?.destroy();
			else StaticObject.getByName(kname)?.destroy();
		});
	}
	return rec.health;
}
