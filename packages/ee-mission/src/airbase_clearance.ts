/** @noSelfInFile */
/*
 * DCS airfield geometry guard for procedurally generated ground units.
 * EECH population placements are map-authored outside movement surfaces
 * (popread.c:2148-2212); DCS does not expose those authored points. The
 * runway/parking envelope below is the DCS-specific safety proxy.
 */
import * as cs from "./campaign_state";
import type { WorldPoint } from "./campaign_types";
import { type AnyCoalition, BLUE, NEUTRAL, RED } from "./sides";

const EDGE_BUFFER_METRES = 200;
const NO_GEOMETRY_RADIUS_METRES = 2500;
const MAX_ATTEMPTS = 12;
let cachedGeneration = -1;
let cachedExtents: Record<string, Disc> = {};
let lastKnownAirfields: Record<string, WorldPoint> = {};
let warnedFailures: Record<string, boolean> = {};

type Disc = { x: number; z: number; radius: number };

function finite(value: number): boolean {
	return value < math.huge && value > -math.huge;
}

function cache(name: string, area: Disc): Disc {
	cachedExtents[name] = area;
	return area;
}

function resetForGeneration(): void {
	if (cachedGeneration === cs.GENERATION) return;
	cachedGeneration = cs.GENERATION;
	cachedExtents = {};
	lastKnownAirfields = {};
	warnedFailures = {};
}

function warnOnce(key: string): void {
	if (warnedFailures[key]) return;
	warnedFailures[key] = true;
	env.info(
		`[airbase_clearance] airbase geometry read failed: ${key}; retaining known bounds`,
	);
}

function airfields(): Array<{ name: string; centre: WorldPoint }> {
	resetForGeneration();
	const result: Array<{ name: string; centre: WorldPoint }> = [];
	const seen: Record<string, boolean> = {};
	const coalitions: AnyCoalition[] = [NEUTRAL, RED, BLUE];
	for (const side of coalitions) {
		const [listOk, bases] = pcall(() => coalition.getAirbases(side));
		if (!listOk || !bases) {
			warnOnce(`coalition ${side}`);
			continue;
		}
		for (let index = 0; index < bases.length; index++) {
			const base = bases[index];
			const [nameOk, name] = pcall(() => base.getName());
			if (!nameOk || !name) {
				warnOnce(`coalition ${side} airbase ${index + 1}`);
				continue;
			}
			const [readOk, data] = pcall(() => ({
				category: base.getDesc()?.category,
				position: base.getPosition().p,
			}));
			if (!readOk || !data) {
				warnOnce(name);
				continue;
			}
			if (data.category !== Airbase.Category.AIRDROME) continue;
			const p = data.position;
			if (!finite(p.x) || !finite(p.z)) {
				warnOnce(name);
				continue;
			}
			if (seen[name]) continue;
			seen[name] = true;
			const centre = { x: p.x, z: p.z };
			lastKnownAirfields[name] = centre;
			result.push({ name, centre });
		}
	}
	for (const [name, centre] of pairs(lastKnownAirfields))
		if (!seen[name]) result.push({ name, centre });
	return result;
}

function extent(name: string, centre: WorldPoint): Disc {
	resetForGeneration();
	const cached = cachedExtents[name];
	if (cached !== undefined) return cached;
	const fallback = {
		x: centre.x,
		z: centre.z,
		radius: NO_GEOMETRY_RADIUS_METRES,
	};
	const [lookupOk, base] = pcall(() => Airbase.getByName(name));
	if (!lookupOk) warnOnce(name);
	if (!lookupOk || base === undefined) return cache(name, fallback);
	const [methodsOk, hasGeometryMethods] = pcall(
		() => base.getRunways !== undefined && base.getParking !== undefined,
	);
	if (!methodsOk) warnOnce(name);
	if (!methodsOk || !hasGeometryMethods) return cache(name, fallback);
	const [runwaysOk, runways] = pcall(() => base.getRunways());
	const [parkingOk, parking] = pcall(() => base.getParking());
	if (!runwaysOk || !parkingOk) warnOnce(name);
	if (!runwaysOk || !parkingOk || !runways || !parking || runways.length === 0)
		return cache(name, fallback);
	let radius = 0;
	for (const runway of runways) {
		const p = runway.position;
		if (
			!p ||
			!finite(p.x) ||
			!finite(p.z) ||
			!finite(runway.length) ||
			!finite(runway.width) ||
			runway.length <= 0 ||
			runway.width <= 0
		)
			return cache(name, fallback);
		// A runway's position may be at its midpoint or threshold. Cover either
		// interpretation by taking a full length from the reported point.
		radius = math.max(
			radius,
			cs.dist2d(centre.x, centre.z, p.x, p.z) +
				runway.length +
				runway.width / 2,
		);
	}
	for (const spot of parking) {
		const p = spot.vTerminalPos;
		if (!p || !finite(p.x) || !finite(p.z)) return cache(name, fallback);
		radius = math.max(radius, cs.dist2d(centre.x, centre.z, p.x, p.z));
	}
	return cache(name, {
		x: centre.x,
		z: centre.z,
		radius: math.max(radius + EDGE_BUFFER_METRES, NO_GEOMETRY_RADIUS_METRES),
	});
}

export function is_clear(x: number, z: number, margin = 0): boolean {
	if (!finite(x) || !finite(z)) return false;
	for (const { name, centre } of airfields()) {
		const area = extent(name, centre);
		if (cs.dist2d(x, z, area.x, area.z) <= area.radius + margin) return false;
	}
	return true;
}

export function find_clear(
	base: WorldPoint,
	initial: WorldPoint,
	margin: number,
	label: string,
): WorldPoint | undefined {
	if (is_clear(initial.x, initial.z, margin)) return initial;
	let safeRadius = NO_GEOMETRY_RADIUS_METRES + EDGE_BUFFER_METRES + margin;
	let bearingX = initial.x - base.x;
	let bearingZ = initial.z - base.z;
	for (const { name, centre } of airfields()) {
		const area = extent(name, centre);
		if (
			cs.dist2d(initial.x, initial.z, area.x, area.z) <=
			area.radius + margin
		) {
			safeRadius = math.max(
				safeRadius,
				area.radius +
					margin +
					cs.dist2d(base.x, base.z, area.x, area.z) +
					EDGE_BUFFER_METRES,
			);
			// The runtime sweeper passes the obstructed unit as both arguments.
			// Its outward direction comes from the airfield centre instead.
			if (bearingX === 0 && bearingZ === 0) {
				bearingX = initial.x - area.x;
				bearingZ = initial.z - area.z;
			}
		}
	}
	let bearing = Math.atan2(bearingZ, bearingX);
	if (bearingX === 0 && bearingZ === 0) {
		let hash = 0;
		for (let index = 1; index <= string.len(label); index++)
			hash += string.byte(label, index);
		bearing = ((hash % MAX_ATTEMPTS) * 2 * math.pi) / MAX_ATTEMPTS;
	}
	for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
		const angle = bearing + (attempt * 2 * math.pi) / MAX_ATTEMPTS;
		const radius = safeRadius + attempt * EDGE_BUFFER_METRES;
		const candidate = cs.snap_land(
			base.x + math.cos(angle) * radius,
			base.z + math.sin(angle) * radius,
			base.x,
			base.z,
		);
		if (
			is_clear(candidate.x, candidate.z, margin) &&
			land.getSurfaceType({ x: candidate.x, y: candidate.z }) !==
				land.SurfaceType.WATER
		)
			return candidate;
	}
	env.info(
		string.format(
			"[airbase_clearance] %s SKIP: no safe ground position after %d attempts",
			label,
			MAX_ATTEMPTS,
		),
	);
	return undefined;
}
