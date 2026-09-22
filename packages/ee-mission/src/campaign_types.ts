/** @noSelfInFile */

import type {
	ControllerAction,
	l_Airbase,
	l_Controller,
	l_Group,
	l_Object,
	l_Position3,
	l_StaticObject,
	l_Unit,
	l_Vec2,
	l_Vec3,
	l_Warehouse,
	l_WorldEvent,
	l_WorldEventHandler,
	MissionCommandPath,
	TriggerColor,
	WorldMarkPanel,
	WorldVolume,
} from "@flying-dice/tslua-dcs-mission-types";
import type { AnyCoalition, Neutral, Side } from "./sides";

/**
 * DCS mission-scripting surface.
 *
 * The DCS API itself comes from `@flying-dice/tslua-dcs-mission-types` (wired in
 * via tsconfig `types`, which supplies the globals `coalition`, `land`, `timer`,
 * `env`, `world`, `trigger`, `Group`, `Unit`, `Airbase`, `StaticObject`,
 * `missionCommands` and `coord`).
 *
 * This block only covers what that package does not:
 *  - short aliases for the package's `l_*` interfaces, so existing annotations
 *    such as `Group` / `Unit` keep working (the package exports the *type* as
 *    `l_Group` and reserves the bare name for the *value*);
 *  - the campaign's own spawn-table shapes, which are mission-data payloads
 *    rather than DCS API objects, so the package has no counterpart;
 *  - `country` and `Object.Category`, which the package does not declare.
 */
declare global {
	// -- aliases onto the package's DCS object types -------------------------
	type Vec2 = l_Vec2;
	type Vec3 = l_Vec3;
	type Position3 = l_Position3;
	type Group = l_Group;
	type Unit = l_Unit;
	type StaticObject = l_StaticObject;
	type Controller = l_Controller;
	type Warehouse = l_Warehouse;
	/** A DCS task/command table: `{ id, params }`. */
	type DcsTask = ControllerAction;
	type SearchVolume = WorldVolume;
	type MarkPanel = WorldMarkPanel;
	/** RGBA, each component 0..1. */
	type MarkupColor = TriggerColor;

	interface DcsDescription {
		category?: number;
		attributes?: Record<string, boolean | undefined>;
		typeName?: string;
		displayName?: string;
	}

	type Airbase = l_Airbase;
	/**
	 * An airbase/heliport handle as returned by `Airbase.getID()`, which DCS
	 * types as `number | string`. It is passed straight back to DCS in
	 * waypoint fields, so the campaign never needs it as a number.
	 */
	type AirbaseId = number | string;

	/**
	 * Any DCS world object the campaign inspects generically (event
	 * participants, scenery hits).
	 *
	 * Deliberately structural rather than `extends l_Object`: in this package
	 * `l_Unit` / `l_StaticObject` do not extend `l_Object`, so `l_Object` is not
	 * a supertype of the concrete classes, and it omits `getLife` / `getDesc`
	 * which DCS does expose here. This lists only what the campaign calls.
	 */
	interface DcsObject {
		isExist(): boolean;
		getPosition(): Position3;
		getPoint(): Vec3;
		getName(): string;
		getID(): number | string;
		getLife(): number;
		getDesc(): DcsDescription;
		getCategory(): number;
		getTypeName(): string;
		destroy(): void;
		getCoalition?(): number;
		getPlayerName?(): string | undefined;
		getGroup?(): Group | undefined;
	}

	/**
	 * The package types `initiator` / `target` / `place` as `unknown` because
	 * their class varies by event ID. The campaign only ever subscribes to
	 * events whose participants are world objects, so they are narrowed here
	 * rather than cast at each of the event handlers.
	 */
	interface DcsEvent extends l_WorldEvent {
		initiator?: DcsObject;
		target?: DcsObject;
		place?: Airbase;
	}

	interface DcsEventHandler extends l_WorldEventHandler {
		onEvent(this: DcsEventHandler, event: DcsEvent): void;
	}

	// -- campaign spawn-table shapes (no package counterpart) ----------------
	/** Payload passed to `coalition.addStaticObject`. */
	interface StaticData {
		name: string;
		[key: string]: unknown;
	}

	interface UnitData {
		name: string;
		type: string;
		x: number;
		y: number;
		heading?: number;
		skill?: string;
		payload?: PayloadData;
		/** DCS FARP parking name, exported by the Mission Editor as "1".."4". */
		parking?: string;
		/** DCS FARP parking identifier, exported by the Mission Editor as "1".."4". */
		parking_id?: string;
		[key: string]: unknown;
	}

	/** Payload passed to `coalition.addGroup`. */
	interface GroupData {
		name: string;
		units: UnitData[];
		route?: { points: WaypointData[] };
		[key: string]: unknown;
	}

	interface WaypointData {
		x: number;
		y: number;
		alt?: number;
		alt_type?: string;
		speed?: number;
		type?: string;
		action?: string;
		ETA?: number;
		ETA_locked?: boolean;
		name?: string;
		formation_template?: string;
		airdromeId?: AirbaseId;
		helipadId?: AirbaseId;
		linkUnit?: AirbaseId;
		[key: string]: unknown;
	}

	interface PylonData {
		CLSID: string;
		num?: number;
	}

	interface PayloadData {
		fuel: number;
		gun?: number;
		flare?: number;
		chaff?: number;
		pylons?: PylonData[];
		unlimited?: {
			fuel: boolean;
			guns: boolean;
			flares: boolean;
			chaff: boolean;
		};
	}

	interface MissionZoneVertex {
		x: number;
		y: number;
	}
	interface MissionZone {
		name?: string;
		type?: number;
		x: number;
		y: number;
		radius?: number;
		color?: number[];
		verticies?: MissionZoneVertex[];
	}
	interface DcsMission {
		triggers?: { zones?: MissionZone[] };
		coalitions?: { blue?: number[]; red?: number[]; neutrals?: number[] };
	}

	// -- not declared by the package ----------------------------------------
	namespace country {
		enum id {
			RUSSIA = 0,
			USA = 2,
			CJTF_BLUE = 80,
			CJTF_RED = 81,
		}
	}

	/**
	 * DCS puts `Category` and `getByName` on the global `Object`, alongside the
	 * standard library's own members.
	 */
	interface ObjectConstructor {
		readonly Category: {
			readonly UNIT: 1;
			readonly WEAPON: 2;
			readonly STATIC: 3;
			readonly BASE: 4;
			readonly SCENERY: 5;
			readonly CARGO: 6;
		};
		getByName(name: string): DcsObject | undefined;
	}

	// -- campaign globals ----------------------------------------------------
	// Declared as `var` so they land on `typeof globalThis`, which is what
	// `lua-types` already types `_G` as. Redeclaring `_G` itself would clash.
	let _DMT_GEN: number | undefined;
	let _DMT_DEBUG: boolean | undefined;
	var DMT_CONFIG: unknown;
	var DMT_ACTIVE_CONFIG: unknown;
	var __dmt_handlers: DcsEventHandler[] | undefined;
	var __dmt_real_addGroup: typeof coalition.addGroup | undefined;
	var __dmt_real_addStatic: typeof coalition.addStaticObject | undefined;
	var __dmt_static_death_handler: DcsEventHandler | undefined;

	function addGroup(
		countryId: number,
		category: number,
		data: GroupData,
	): Group | undefined;
	function addStatic(
		countryId: number,
		data: StaticData,
	): StaticObject | Group | undefined;

	/**
	 * Overload merged onto `lua-types`' own `require`, so the campaign's
	 * `require<Module>("name")` module handles stay typed.
	 */
	function require<T>(moduleName: string): T;
}

declare module "@flying-dice/tslua-dcs-mission-types" {
	/** `env.mission` is the parsed mission table; the package does not declare it. */
	interface l_env {
		mission?: DcsMission;
	}

	/**
	 * DCS invokes an F-10 menu callback as `callback(argument)`, with no
	 * receiver. The package declares these callbacks as `(argument: T) => void`,
	 * which TSTL reads as taking an implicit `self`, so passing a plain function
	 * fails to compile. These overloads restate the same signatures with an
	 * explicit `this: void`, which is the calling convention DCS actually uses.
	 *
	 * `@noSelf` must be repeated here: it is not inherited from the package's
	 * own declaration, and without it TSTL emits `missionCommands:addCommand...`
	 * colon calls, which would shift every argument by one at runtime.
	 *
	 * @noSelf
	 */
	interface l_missionCommands {
		addCommand<T>(
			name: string,
			path: MissionCommandPath | undefined,
			callback: (this: void, argument: T) => void,
			argument: T,
		): MissionCommandPath;
		addCommandForCoalition<T>(
			coalitionId: number,
			name: string,
			path: MissionCommandPath | undefined,
			callback: (this: void, argument: T) => void,
			argument: T,
		): MissionCommandPath;
		addCommandForGroup<T>(
			groupId: number,
			name: string,
			path: MissionCommandPath | undefined,
			callback: (this: void, argument: T) => void,
			argument: T,
		): MissionCommandPath;
	}
}

/**
 * A combatant coalition: RED (1) or BLUE (2).
 *
 * Re-exported from `./sides`, which owns the closed RED/BLUE domain and the
 * single validated narrowing of the DCS `coalition.side` table. Import the
 * `RED` / `BLUE` constants from `./sides` rather than reading
 * `coalition.side.*`, which the types package widens to plain `number`.
 */
export type { AnyCoalition, Neutral, Side };
export type WorldPoint = { x: number; z: number; y?: number };
export type TaskResult = "success" | "partial" | "failure";
export type TaskTermination = "route_complete" | "terminated";
export type StatCategory =
	| "air"
	| "heli"
	| "ground"
	| "ship"
	| "structure"
	| "other";

export interface TaskInfo {
	task_type: string;
	side: Side;
	target_base?: string;
	target_pos?: WorldPoint;
	objective?: { kind: string; base?: string; group?: Group; pos?: WorldPoint };
	born_time?: number;
	eff_before?: number;
	role?: string;
	launch_base?: string;
	producer_pos?: WorldPoint;
	picked_up?: boolean;
	commodity?: string;
	[key: string]:
		| string
		| number
		| boolean
		| WorldPoint
		| { kind: string; base?: string; group?: Group; pos?: WorldPoint }
		| undefined;
}

export interface ForceStats {
	kills: Partial<Record<StatCategory, number>>;
	losses: Partial<Record<StatCategory, number>>;
	sorties: number;
	tasks_created: number;
	tasks_completed: number;
	tasks_partial: number;
	tasks_failed: number;
}

export interface InventoryLedger {
	striker: number;
	escort: number;
	heli: number;
	recon: number;
	transport: number;
	vehicle: number;
}

export interface GroundGroupRecord {
	grp: Group;
	target_base?: string;
	home_base: string;
	want?: number;
}

export interface ArtilleryGroupRecord {
	grp: Group;
	home_base: string;
	moving_to?: string;
}
export interface SecondaryGroupRecord {
	grp: Group;
	home_base: string;
	want: number;
	behind_base?: string;
}

export interface SceneryAssetRecord {
	id: string;
	type: string;
	handle: DcsObject;
	life0?: number;
	dead?: boolean;
}

export interface KeysiteFlags {
	ground_strike_target: boolean;
	recon_target: boolean;
	requires_cap?: boolean;
	requires_barcap?: boolean;
	oca_target?: boolean;
	troop_insertion_target?: boolean;
}

export interface KeysiteRecord {
	kind: string;
	label?: string;
	side?: Side;
	home_base?: string;
	pos: WorldPoint;
	health: number;
	pending?: boolean;
	low_targets?: boolean;
	assets?: string[];
	dead?: Record<string, boolean> & { [index: number]: string };
	scenery?: SceneryAssetRecord[];
	total?: number;
	alive?: number;
	producer?: { ammo: number; fuel: number };
	flags: KeysiteFlags;
	templated?: boolean;
	requires_cap?: boolean;
	spawn_kind?: "static" | "unit";
}

export interface RegenEntry {
	base_name: string;
	aircraft_type: string;
	enqueued: number;
}
export interface ProductionState {
	ammo: number;
	fuel: number;
	ammo_rr: number;
	fuel_rr: number;
	ammo_earmark: number;
	fuel_earmark: number;
}

export interface CampaignState {
	start_time: number;
	game_over: boolean;
	winner?: Side;
	base_health: Record<string, number>;
	base_owner: Record<string, Side>;
	base_pos: Record<string, WorldPoint>;
	base_efficiency: Record<string, number>;
	base_kind: Record<string, string>;
	objectives: Record<number, string[]>;
	strength: Record<number, number>;
	ground_groups: Record<number, Record<string, GroundGroupRecord>>;
	arty_groups: Record<number, Record<string, ArtilleryGroupRecord>>;
	counter_battery: Record<string, number>;
	base_ledger: Record<string, InventoryLedger>;
	base_inflight: Record<string, number>;
	group_launch_base: Record<string, string>;
	force_current: Record<number, number>;
	base_idle_groups: Record<string, number>;
	active_tasks: Record<string, TaskInfo>;
	board_tasks: BoardTask[];
	board_failed: number;
	farp_active: Record<string, boolean>;
	stats: Record<number, ForceStats>;
	pending_captures: Record<string, boolean>;
	imap: {
		raw: Record<string, Record<Side, Record<string, number>>>;
		nrm: Record<string, Record<Side, Record<string, number>>>;
	};
	fow: Record<string, Partial<Record<Side, number>>>;
	keysites: Record<string, KeysiteRecord>;
	pilots: Record<string, PilotRecord>;
	spawn_queue: SpawnItem[];
	_spawn_seq: number;
	_spawn_drain_reported: boolean;
	patrol_groups: Record<string, string>;
	regen_queue: Record<number, Record<string, RegenEntry[]>>;
	production: Record<number, ProductionState>;
	base_ammo: Record<string, number>;
	base_fuel: Record<string, number>;
	/** Per-base aircraft-type -> count summary, built in `keysite`. */
	base_warehouse: Record<string, Record<string, number>>;
	base_assign_toggle: Record<string, boolean>;
	base_last_strike: Record<string, number>;
	base_ad_groups: Record<string, string[]>;
	base_fp_groups: Record<string, string[]>;
	sec_groups: Record<number, Record<string, SecondaryGroupRecord>>;
	keysite_assist_timer: Record<string, number>;
	supply_delivered: Record<string, boolean>;
	supply_heavy_flag: boolean;
	_completed: Record<string, boolean>;
	_recycled: Record<string, boolean>;
	_board_diag: Record<string, number>;
}

export type LogFunction = (this: void, message: string) => void;

export type BoardTaskState = "UNASSIGNED" | "ASSIGNED" | "FAILED";
export type BoardRole =
	| "striker"
	| "escort"
	| "recon"
	| "heli"
	| "transport"
	| "vehicle"
	| "player";

export interface BoardTarget {
	base?: string;
	pos?: WorldPoint;
	group?: Group;
	objective?: { kind: string; base?: string; group?: Group; pos?: WorldPoint };
	commodity?: string;
	producer_name?: string;
	producer_pos?: WorldPoint;
}

export interface BoardTaskSpec {
	type: string;
	side: Side;
	target?: BoardTarget;
	count?: number;
	builder: (baseName: string) => Group | undefined;
	priority?: number;
	critical?: boolean;
	expiry?: number;
	immediate?: boolean;
	log_fn?: LogFunction;
	origin?: string;
	exclude_target_base?: boolean;
}

export interface BoardTask {
	id: number;
	type: string;
	side: Side;
	target: BoardTarget;
	count: number;
	builder: (baseName: string) => Group | undefined;
	log_fn: LogFunction;
	origin: string;
	priority: number;
	critical: boolean;
	created_t: number;
	expiry_t: number;
	state: BoardTaskState;
	assigned_group?: string;
	dedup_key: string;
	exclude_target_base: boolean;
	role?: BoardRole;
	base?: string;
	player?: boolean;
	_dbg_logged?: boolean;
}

export type SpawnItem =
	| {
			kind: "group";
			country: number;
			category: number;
			data: GroupData;
			name: string;
			seq: number;
			deferred_setTask?: DcsTask;
			deferred_pushTask?: DcsTask;
	  }
	| {
			kind: "static";
			country: number;
			data: StaticData;
			name: string;
			seq: number;
			deferred_setTask?: DcsTask;
			deferred_pushTask?: DcsTask;
	  };

export interface PilotRecord {
	name: string;
	side?: Side;
	score: number;
	rank: number;
	kills: {
		air: number;
		ground: number;
		sea: number;
		fixed: number;
		fixed_wing: number;
		helicopter: number;
		air_defence: number;
		armour: number;
		artillery: number;
		friendly: number;
		total: number;
		deaths?: number;
	};
	medals: Record<string, number>;
	sorties: number;
	deaths: number;
	missions_flown: number;
	air_medal_counter: number;
	sortie_score_start: number;
	sortie_damaged: boolean;
	first_seen: number;
	last_brief_t?: number;
}
