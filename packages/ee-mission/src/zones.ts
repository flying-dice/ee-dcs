/** @noSelfInFile */
/*
-- zones.lua — read author-placed Mission Editor trigger zones and test points against them.
-- Lets the campaign layout be AUTHORED in the ME (theatre bounds, side ownership, objectives, no-go
-- areas) instead of auto-derived. Supports both CIRCLE and QUAD (box) zones.
--
-- Coordinate mapping: in the mission file, zone geometry uses (x, y) where x = world x (north) and
-- y = world z (east). We normalise to world (x, z).
*/
import * as cs from "./campaign_state";
import type { SceneryAssetRecord, Side, WorldPoint } from "./campaign_types";
interface LoadedZone {
	name: string;
	color?: number[];
	cx: number;
	cz: number;
	radius?: number;
	verts?: WorldPoint[];
}
export interface KeysiteZone {
	type: string;
	side?: Side;
	x: number;
	z: number;
	label: string;
}
let loaded: Record<string, LoadedZone> = {};
// DCS Mission Editor serialises quadrilateral trigger zones with type=2.
const MISSION_ZONE_QUAD = 2;
// Non-zero fallback prevents division by zero for a horizontal polygon edge.
const POLYGON_EDGE_EPSILON = 1e-9;
const kinds: Record<string, boolean> = {
	airbase: true,
	farp: true,
	factory: true,
	refinery: true,
	port: true,
	radar: true,
	depot: true,
	power: true,
	command: true,
	fuel: true,
};
function firstWord(name?: string): string {
	if (!name) return "";
	const [matched] = string.match(name, "^%s*(%a+)");
	return string.lower(matched ?? "");
}
function pointInPoly(px: number, pz: number, verts: WorldPoint[]): boolean {
	let inside = false,
		j = verts.length - 1;
	for (let i = 0; i < verts.length; i += 1) {
		const vi = verts[i],
			vj = verts[j];
		if (
			vi.z > pz !== vj.z > pz &&
			px <
				((vj.x - vi.x) * (pz - vi.z)) /
					(vj.z - vi.z !== 0 ? vj.z - vi.z : POLYGON_EDGE_EPSILON) +
					vi.x
		)
			inside = !inside;
		j = i;
	}
	return inside;
}
export function load(): number {
	loaded = {};
	const zones = env.mission?.triggers?.zones;
	if (!zones) {
		cs.dbg(
			"zones",
			"load: no env.mission.triggers.zones table found -> 0 zones",
		);
		return 0;
	}
	let count = 0;
	for (const zone of zones)
		if (zone.name) {
			let record: LoadedZone;
			if (zone.type === MISSION_ZONE_QUAD && zone.verticies) {
				const verts = zone.verticies.map((vertex) => ({
					x: vertex.x,
					z: vertex.y,
				}));
				let sx = 0,
					sz = 0;
				for (const vertex of verts) {
					sx += vertex.x;
					sz += vertex.z;
				}
				record = {
					name: zone.name,
					color: zone.color,
					verts,
					cx: sx / Math.max(verts.length, 1),
					cz: sz / Math.max(verts.length, 1),
				};
			} else
				record = {
					name: zone.name,
					color: zone.color,
					cx: zone.x,
					cz: zone.y,
					radius: zone.radius ?? 0,
				};
			loaded[zone.name.toLowerCase()] = record;
			count += 1;
		}
	let keysites = 0;
	for (const zone of Object.values(loaded))
		if (kinds[firstWord(zone.name)]) keysites += 1;
	cs.dbg(
		"zones",
		"load: %d zones loaded (%d recognised as keysite zones)",
		count,
		keysites,
	);
	return count;
}
export function exists(name: string): boolean {
	return loaded[name.toLowerCase()] !== undefined;
}
export function contains(name: string, wx: number, wz: number): boolean {
	const zone = loaded[name.toLowerCase()];
	if (!zone) return false;
	return zone.verts
		? pointInPoly(wx, wz, zone.verts)
		: cs.dist2d(wx, wz, zone.cx, zone.cz) <= (zone.radius ?? 0);
}
export function statics_in_zone(zone_name: string): string[] {
	const result: string[] = [];
	for (const side of [
		coalition.side.BLUE,
		coalition.side.RED,
		coalition.side.NEUTRAL,
	]) {
		try {
			for (const object of coalition.getStaticObjects(side) ?? []) {
				const point = object.getPoint();
				if (contains(zone_name, point.x, point.z))
					result.push(object.getName());
			}
		} catch (_error) {
			/* DCS handle race */
		}
	}
	return result;
}
export const RESOURCE_SCENERY: Record<string, boolean> = {
	AIRBASE_BARRELS_01: true,
	PAR_GSM: true,
	"TOPLIVO-BAK_NEW": true,
	SKLADIK: true,
};
function isResource(
	typeName: string | undefined,
	set: Record<string, boolean>,
): boolean {
	if (!typeName) return false;
	const upper = typeName.toUpperCase();
	if (set[upper]) return true;
	if (
		upper.includes("POLE") ||
		upper.includes("POLY") ||
		upper.includes("LIGHT") ||
		upper.includes("TREE")
	)
		return false;
	return (
		upper.includes("FUEL") ||
		upper.includes("BARREL") ||
		upper.includes("WARE") ||
		upper.includes("DEPOT") ||
		upper.includes("GSM") ||
		upper.includes("STORAGE") ||
		upper.includes("TOPLIVO")
	);
}
function boundingRadius(zone: LoadedZone): number {
	if (zone.radius !== undefined && zone.radius > 0) return zone.radius;
	let radius = 0;
	for (const vertex of zone.verts ?? [])
		radius = Math.max(radius, cs.dist2d(zone.cx, zone.cz, vertex.x, vertex.z));
	return radius;
}
export function scenery_in_zone(
	zone_name: string,
	type_set: Record<string, boolean> = RESOURCE_SCENERY,
): SceneryAssetRecord[] {
	const result: SceneryAssetRecord[] = [],
		zone = loaded[zone_name.toLowerCase()];
	if (!zone) return result;
	const radius = boundingRadius(zone);
	if (radius <= 0) return result;
	const seen: Record<string, boolean> = {};
	const volume: SearchVolume = {
		id: world.VolumeType.SPHERE,
		params: { point: { x: zone.cx, y: 0, z: zone.cz }, radius },
	};
	try {
		world.searchObjects(Object.Category.SCENERY, volume, (object) => {
			try {
				const type = object.getTypeName();
				if (!isResource(type, type_set)) return true;
				const point = object.getPoint();
				if (!contains(zone_name, point.x, point.z)) return true;
				const id = object.getName();
				if (!id || seen[id]) return true;
				seen[id] = true;
				result.push({ id, type, handle: object, life0: object.getLife() });
			} catch (_error) {
				/* continue enumeration */
			}
			return true;
		});
	} catch (_error) {
		/* unavailable search API */
	}
	return result;
}
export function names(): string[] {
	return Object.keys(loaded);
}
function isColorTable(
	value: unknown,
): value is { color?: unknown; [index: number]: unknown } {
	return type(value) === "table";
}
export function side_of_color(zone: unknown): Side | undefined {
	if (!isColorTable(zone)) return undefined;
	const color = zone.color ?? zone;
	if (!isColorTable(color)) return undefined;
	// Raw numeric keys preserve sparse Lua color tables; Array.isArray requires index 1.
	const red = typeof color[1] === "number" ? color[1] : 0;
	const blue = typeof color[3] === "number" ? color[3] : 0;
	return blue > red
		? coalition.side.BLUE
		: red > blue
			? coalition.side.RED
			: undefined;
}
export function keysites(): KeysiteZone[] {
	const result: KeysiteZone[] = [];
	for (const zone of Object.values(loaded)) {
		const kind = firstWord(zone.name);
		if (kinds[kind])
			result.push({
				type: kind,
				side: side_of_color(zone),
				x: zone.cx,
				z: zone.cz,
				label: zone.name,
			});
	}
	return result;
}
export function has_keysite_zones(): boolean {
	for (const zone of Object.values(loaded))
		if (kinds[firstWord(zone.name)]) return true;
	return false;
}
