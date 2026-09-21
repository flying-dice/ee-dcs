/** @noSelfInFile */
/** Ambient declarations for the DCS mission-scripting environment. */

interface Vec2 {
	x: number;
	y: number;
}
interface Vec3 {
	x: number;
	y: number;
	z: number;
}
interface Position3 {
	p: Vec3;
	x: Vec3;
	y: Vec3;
	z: Vec3;
}

interface DcsDescription {
	category?: number;
	attributes?: Record<string, boolean | undefined>;
	typeName?: string;
	displayName?: string;
}

interface Controller {
	setTask(this: Controller, task: DcsTask): void;
	pushTask(this: Controller, task: DcsTask): void;
	resetTask(this: Controller): void;
	setCommand(this: Controller, command: DcsTask): void;
	setOption(this: Controller, option: number, value: number | boolean): void;
}
type DcsTask = Record<string, unknown>;
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
	airdromeId?: number;
	helipadId?: number;
	linkUnit?: number;
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
	unlimited?: { fuel: boolean; guns: boolean; flares: boolean; chaff: boolean };
}

interface DcsObject {
	isExist(this: DcsObject): boolean;
	getPosition(this: DcsObject): Position3;
	getPoint(this: DcsObject): Vec3;
	getName(this: DcsObject): string;
	getID(this: DcsObject): number;
	getLife(this: DcsObject): number;
	getDesc(this: DcsObject): DcsDescription;
	getCategory(this: DcsObject): number;
	getTypeName(this: DcsObject): string;
	destroy(this: DcsObject): void;
	getCoalition?(this: DcsObject): coalition.side;
	getPlayerName?(this: DcsObject): string | undefined;
	getGroup?(this: DcsObject): Group | undefined;
}

interface Unit extends DcsObject {
	getGroup(this: Unit): Group | undefined;
	getPlayerName(this: Unit): string | undefined;
	getCoalition(this: Unit): coalition.side;
	inAir(this: Unit): boolean;
}

interface Group {
	isExist(this: Group): boolean;
	getPosition?(this: Group): Position3;
	getName(this: Group): string;
	getID(this: Group): number;
	getUnit(this: Group, index: number): Unit | undefined;
	getUnits(this: Group): Unit[] | undefined;
	getController(this: Group): Controller;
	getCategory(this: Group): number | undefined;
	getCoalition(this: Group): coalition.side | undefined;
	getSize(this: Group): number;
	getInitialSize?(this: Group): number;
	destroy(this: Group): void;
}

interface Airbase {
	getID(this: Airbase): number;
	getName(this: Airbase): string;
	getPosition(this: Airbase): Position3;
	getPoint(this: Airbase): Vec3;
	getDesc(this: Airbase): DcsDescription;
	getWarehouse(this: Airbase): Warehouse;
}

interface WarehouseInventory {
	aircraft?: Record<string, number>;
	[key: string]: unknown;
}
interface Warehouse {
	getInventory(this: Warehouse): WarehouseInventory;
}

interface StaticObject extends DcsObject {
	destroy(this: StaticObject): void;
}

declare namespace coalition {
	enum side {
		NEUTRAL = 0,
		RED = 1,
		BLUE = 2,
	}
	function addGroup(
		countryId: number,
		category: number,
		data: GroupData,
	): Group | undefined;
	function getGroups(side: side, category?: number): Group[] | undefined;
	function addStaticObject(
		countryId: number,
		data: StaticData,
	): StaticObject | Group | undefined;
	function getPlayers(side: side): Unit[] | undefined;
	function getStaticObjects(side: side): StaticObject[] | undefined;
	function getAirbases(side: side): Airbase[] | undefined;
}

declare namespace Group {
	enum Category {
		AIRPLANE = 0,
		HELICOPTER = 1,
		GROUND = 2,
		SHIP = 3,
		TRAIN = 4,
	}
	function getByName(name: string): Group | undefined;
}
type GroupInstance = Group;

declare namespace Unit {
	function getByName(name: string): Unit | undefined;
	function getDescByName(name: string): DcsDescription | undefined;
}
type UnitInstance = Unit;

declare namespace Airbase {
	enum Category {
		AIRDROME = 0,
		HELIPAD = 1,
		SHIP = 2,
	}
	function getByName(name: string): Airbase | undefined;
}
type AirbaseInstance = Airbase;

declare namespace StaticObject {
	function getByName(name: string): StaticObject | undefined;
}
type StaticObjectInstance = StaticObject;

type DcsObjectCategory = 1 | 2 | 3 | 4 | 5 | 6;
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

declare namespace timer {
	function getTime(): number;
	function scheduleFunction<T>(
		fn: (arg: T, time: number) => number | undefined,
		arg: T,
		time: number,
	): number;
}

declare namespace trigger.action {
	function outText(text: string, seconds: number, clearView?: boolean): void;
	function removeMark(id: number): void;
	function markToAll(
		id: number,
		text: string,
		pos: Vec3,
		readOnly?: boolean,
		message?: string,
	): void;
	function markToCoalition(
		id: number,
		text: string,
		pos: Vec3,
		side: coalition.side,
		readOnly?: boolean,
		message?: string,
	): void;
	function outTextForGroup(
		groupId: number,
		text: string,
		seconds: number,
		clearView?: boolean,
	): void;
	function outTextForCoalition(
		side: coalition.side,
		text: string,
		seconds: number,
		clearView?: boolean,
	): void;
	function lineToAll(
		coalition: number,
		id: number,
		from: Vec3,
		to: Vec3,
		color: number[],
		lineType: number,
		readOnly?: boolean,
		message?: string,
	): void;
	function textToAll(
		coalition: number,
		id: number,
		pos: Vec3,
		color: number[],
		fillColor: number[],
		fontSize: number,
		readOnly: boolean,
		text: string,
	): void;
	function circleToAll(
		coalition: number,
		id: number,
		center: Vec3,
		radius: number,
		color: number[],
		fillColor: number[],
		lineType: number,
		readOnly?: boolean,
		message?: string,
	): void;
}

interface DcsEvent {
	id: number;
	/** Event initiators can be units, statics, weapons, or other DCS objects. */
	initiator?: DcsObject;
	target?: DcsObject;
	place?: Airbase;
}
interface DcsEventHandler {
	onEvent(this: DcsEventHandler, event: DcsEvent): void;
}
interface MarkPanel {
	idx?: number;
	text?: string;
	pos?: Vec3;
	coalition?: number;
}
interface SearchVolume {
	id: world.VolumeType;
	params: { point: Vec3; radius: number };
}
declare namespace world {
	enum event {
		S_EVENT_SHOT = 1,
		S_EVENT_HIT = 2,
		S_EVENT_TAKEOFF = 3,
		S_EVENT_LAND = 4,
		S_EVENT_CRASH = 5,
		S_EVENT_EJECTION = 6,
		S_EVENT_DEAD = 8,
		S_EVENT_BIRTH = 15,
		S_EVENT_KILL = 28,
	}
	enum VolumeType {
		SEGMENT = 0,
		BOX = 1,
		SPHERE = 2,
		PYRAMID = 3,
	}
	function addEventHandler(handler: WorldEventHandler): void;
	function removeEventHandler(handler: WorldEventHandler): void;
	function searchObjects(
		category: DcsObjectCategory,
		volume: SearchVolume,
		handler: (object: DcsObject) => boolean,
	): void;
	function getMarkPanels(): MarkPanel[] | undefined;
	function getAirbases(): Airbase[];
}

declare namespace land {
	enum SurfaceType {
		LAND = 1,
		SHALLOW_WATER = 2,
		WATER = 3,
		ROAD = 4,
		RUNWAY = 5,
	}
	function getHeight(point: Vec2): number;
	function getSurfaceType(point: Vec2): SurfaceType;
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
declare namespace env {
	const mission: DcsMission | undefined;
	function info(message: string): void;
}
declare namespace country {
	enum id {
		RUSSIA = 0,
		USA = 2,
		CJTF_BLUE = 80,
		CJTF_RED = 81,
	}
}

declare namespace missionCommands {
	function addCommand<T>(
		name: string,
		path: unknown,
		handler: (this: void, arg: T) => void,
		arg: T,
	): unknown;
	function addCommandForCoalition<T>(
		side: coalition.side,
		name: string,
		path: unknown,
		handler: (this: void, arg: T) => void,
		arg: T,
	): unknown;
	function addCommandForGroup<T>(
		groupId: number,
		name: string,
		path: unknown,
		handler: (this: void, arg: T) => void,
		arg: T,
	): unknown;
	function addSubMenu(name: string, path?: unknown): unknown;
	function addSubMenuForCoalition(
		side: coalition.side,
		name: string,
		path?: unknown,
	): unknown;
	function addSubMenuForGroup(
		groupId: number,
		name: string,
		path?: unknown,
	): unknown;
	function removeItem(path: unknown): void;
	function removeItemForCoalition(side: coalition.side, path: unknown): void;
	function removeItemForGroup(groupId: number, path: unknown): void;
}

declare let _DMT_GEN: number | undefined;
declare let _DMT_DEBUG: boolean | undefined;
declare const _G: {
	DMT_CONFIG?: unknown;
	DMT_ACTIVE_CONFIG?: unknown;
	_DMT_GEN?: number;
	_DMT_DEBUG?: boolean;
	__dmt_handlers?: DcsEventHandler[];
	__dmt_real_addGroup?: typeof coalition.addGroup;
	__dmt_real_addStatic?: typeof coalition.addStaticObject;
	__dmt_static_death_handler?: DcsEventHandler;
	dcs_studio?: import("./persist").Bridge;
};

declare function addGroup(
	countryId: number,
	category: number,
	data: GroupData,
): Group | undefined;
declare function addStatic(
	countryId: number,
	data: StaticData,
): StaticObject | Group | undefined;

declare function require<T>(moduleName: string): T;
