/** @noSelfInFile */

export type Side = coalition.side.BLUE | coalition.side.RED;
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
	base_warehouse: Record<string, WarehouseInventory>;
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
