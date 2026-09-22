/** @noSelfInFile */
/*
-- croute.lua
-- Inspired by:
--   aphavoc/source/ai/taskgen/croute.c   BIASED ROUTE GENERATOR — the whole file.
--     route_biasing_database[MOVEMENT_TYPE_AIR]  (croute.c:126-135)  the AIR profile constants
--     create_route / generate_best_mid_point     (croute.c:1242-1309) recursive perpendicular search
--     get_best_point                             (croute.c:1315-1458) sample the perpendicular sweep
--     get_route_point_rating                     (croute.c:1502-1553) elevation + range + side cost
--     second_past_route                          (croute.c:1464-1496) one smoothing re-optimise pass
--     optimise_route                             (croute.c:1559-1669) prune near-colinear nodes
--     generate_biased_vec3d_route                (croute.c:1132-1236) per-leg driver + stitch
--
-- WHY: EECH does NOT fly straight lines between keysites. Every AI air/heli group's route is run
-- through this biased generator, which recursively drops nav nodes onto the LOWEST terrain, nearest
-- OWN territory, near the leg centreline — i.e. valley-following, enemy-sector-avoiding, dispersed
-- routes. The port previously flew depart->target->RTB as three points (a straight "kill corridor");
-- this module reproduces the EECH algorithm so every builder's legs bend through cover.
--
-- SCOPE: this module is PURE route geometry (no spawning, no DCS group calls). `M.biased_route`
-- ports create_route+second_past_route+optimise_route for ONE leg; `M.expand` walks a DCS `points`
-- list and stitches biased nav points between consecutive waypoints (the generate_biased_vec3d_route
-- multi-leg loop). All airborne movement is MOVEMENT_TYPE_AIR in EECH (group_database movement_type
-- for aircraft/helicopters), so there is a single profile — no config, no scenario data: these are
-- EECH C constants, cited above.
--
-- PORT DEVIATIONS (documented, not invented):
--  * sector_side proxy: EECH reads get_local_sector_entity(test_point)->SECTOR_SIDE (croute.c:1534-1536)
--    off its fine authored sector grid. The port has no sector grid — bases ARE the sectors (the same
--    convention campaign_state.route_difficulty uses, task.c:876). So sector_side(test_point) = owner of
--    the NEAREST base. nil owner (no base / unowned) -> treated as NOT own side (biased against), per spec.
--  * elevation: EECH get_3d_terrain_elevation (croute.c:1389) -> DCS pcall(land.getHeight,{x,y=z}); a
--    failed/out-of-map probe defaults to 0 (then max(avg,0), matching croute.c:1526). Memoised per
--    biased_route call (quantised key) to bound land.getHeight to ~one probe per distinct sample point.
--  * hard recursion depth cap (DEPTH_CAP): min_route_range (5000 m, croute.c:1347) is the REAL
--    terminator — a leg subdivides until each half is <= 5 km. The depth cap is only a safety bound so a
--    pathological/degenerate leg can never recurse unboundedly; at 5 km termination a 100 km leg reaches
--    depth ~5, so DEPTH_CAP=6 is never the binding limit on real routes.
--  * nav points are NOT land-snapped: they are flown at cruise altitude (nav waypoints), so they may sit
--    over water/steep ground exactly as EECH's do (EECH never snaps nav nodes either; only the elevation
--    RATING cares about terrain height).
--  * per-leg nav cap (MAX_NAV_PER_LEG): a DCS route table safety cap (DCS is fine to ~20 points/route;
--    we keep <=8 inserted nav points per leg after the optimise prune). Not an EECH constant; on real
--    legs the colinear prune already yields ~3-8, so this only guards degenerate long legs.
*/
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";

const S = cs.S;
// EECH MOVEMENT_TYPE_AIR profile, croute.c:126-135 (metres and unitless weights).
const ELEVATION_BIAS = 5.0,
	RANGE_BIAS = 0.5,
	SIDE_BIAS = 1.0,
	MIN_ROUTE_RANGE_METRES = 5000.0;
const DEVIATION_SIZE = 3.0,
	NUM_SAMPLES = 8,
	OPT_TOLERANCE = 0.94;
// DCS adapter safety limits documented in the module header.
const DEPTH_CAP = 6,
	MAX_NAV_PER_LEG = 8;
const DEFAULT_NAV_ALTITUDE_METRES = 3000;
const DEFAULT_NAV_SPEED_METRES_PER_SECOND = 200;
const METRES_PER_KILOMETRE = 1000;

function sectorSide(x: number, z: number): Side | undefined {
	let best: string | undefined;
	let distance = math.huge;
	for (const [name, pos] of Object.entries(S.base_pos)) {
		const dx = x - pos.x,
			dz = z - pos.z,
			d2 = dx * dx + dz * dz;
		if (d2 < distance) {
			distance = d2;
			best = name;
		}
	}
	return best ? S.base_owner[best] : undefined;
}
export function biased_route(
	start_pos: WorldPoint,
	end_pos: WorldPoint,
	side: Side,
): WorldPoint[] {
	const elevations: Record<string, number> = {};
	const terrain = (x: number, z: number): number => {
		// String coordinates preserve the one-metre quantisation without numeric key collisions.
		const key = `${Math.floor(x + 0.5)}:${Math.floor(z + 0.5)}`;
		if (elevations[key] === undefined) {
			try {
				elevations[key] = land.getHeight({ x, y: z });
			} catch (_error) {
				elevations[key] = 0;
			}
		}
		return elevations[key];
	};
	const bestPoint = (
		ax: number,
		az: number,
		bx: number,
		bz: number,
	): WorldPoint | undefined => {
		const dx = bx - ax,
			dz = bz - az,
			squared = dx * dx + dz * dz;
		if (squared <= MIN_ROUTE_RANGE_METRES * MIN_ROUTE_RANGE_METRES)
			return undefined;
		const incX = dz / (NUM_SAMPLES * DEVIATION_SIZE),
			incZ = -dx / (NUM_SAMPLES * DEVIATION_SIZE);
		const sx = ax + dx * 0.5 - incX * NUM_SAMPLES * 0.5,
			sz = az + dz * 0.5 - incZ * NUM_SAMPLES * 0.5;
		const elev: number[] = [];
		let tx = sx,
			tz = sz;
		for (const _i of $range(1, NUM_SAMPLES)) {
			elev.push(terrain(tx, tz));
			tx += incX;
			tz += incZ;
		}
		const rating = (sample: number, x: number, z: number): number => {
			const index = sample - 1,
				lo = Math.max(sample - 1, 1) - 1,
				hi = Math.min(sample + 1, NUM_SAMPLES) - 1;
			const average = Math.max(0, (elev[index] + elev[lo] + elev[hi]) / 3);
			const range =
				(RANGE_BIAS * Math.abs(2 * sample - NUM_SAMPLES)) / (NUM_SAMPLES * 2);
			const weight = Math.max(average, 1);
			return (
				ELEVATION_BIAS * average +
				range * weight +
				(sectorSide(x, z) !== side ? SIDE_BIAS * weight : 0)
			);
		};
		let best = { x: sx, z: sz },
			bestRating = rating(1, sx, sz);
		tx = sx;
		tz = sz;
		for (const i of $range(1, NUM_SAMPLES - 1)) {
			tx += incX;
			tz += incZ;
			const value = rating(i + 1, tx, tz);
			if (value < bestRating) {
				bestRating = value;
				best = { x: tx, z: tz };
			}
		}
		return best;
	};
	const nodes: WorldPoint[] = [{ x: start_pos.x, z: start_pos.z }];
	let generated = 0;
	const subdivide = (a: WorldPoint, b: WorldPoint, depth: number): void => {
		if (depth >= DEPTH_CAP) return;
		const mid = bestPoint(a.x, a.z, b.x, b.z);
		if (!mid) return;
		subdivide(a, mid, depth + 1);
		nodes.push(mid);
		generated += 1;
		subdivide(mid, b, depth + 1);
	};
	subdivide(start_pos, end_pos, 0);
	nodes.push({ x: end_pos.x, z: end_pos.z });
	for (let i = 1; i < nodes.length - 1; i += 1) {
		const mid = bestPoint(
			nodes[i - 1].x,
			nodes[i - 1].z,
			nodes[i + 1].x,
			nodes[i + 1].z,
		);
		if (mid) nodes[i] = mid;
	}
	let i = 1;
	while (i < nodes.length - 1) {
		const prev = nodes[i - 1],
			node = nodes[i],
			next = nodes[i + 1];
		const v1x = node.x - prev.x,
			v1z = node.z - prev.z,
			v2x = next.x - node.x,
			v2z = next.z - node.z;
		const l1 = v1x * v1x + v1z * v1z,
			l2 = v2x * v2x + v2z * v2z;
		const remove =
			l1 === 0 ||
			l2 === 0 ||
			Math.abs(
				(v1x / Math.sqrt(l1)) * (v2x / Math.sqrt(l2)) +
					(v1z / Math.sqrt(l1)) * (v2z / Math.sqrt(l2)),
			) > OPT_TOLERANCE;
		if (remove) nodes.splice(i, 1);
		else i += 1;
	}
	let nav = nodes.slice(1, nodes.length - 1);
	if (nav.length > MAX_NAV_PER_LEG) {
		const source = nav;
		nav = [];
		const step = source.length / MAX_NAV_PER_LEG;
		for (const k of $range(1, MAX_NAV_PER_LEG))
			nav.push(
				source[Math.min(source.length - 1, Math.floor((k - 0.5) * step))],
			);
	}
	cs.dbg(
		"croute",
		"leg %.1fkm: %d node(s) generated, %d after prune/cap",
		cs.dist2d(start_pos.x, start_pos.z, end_pos.x, end_pos.z) /
			METRES_PER_KILOMETRE,
		generated,
		nav.length,
	);
	return nav;
}
export interface ExpandOptions {
	alt?: number;
	alt_type?: string;
	speed?: number;
	name?: string;
}
export function expand(
	points: WaypointData[],
	side: Side,
	opts: ExpandOptions = {},
): WaypointData[] {
	if (points.length < 2) return points;
	const out: WaypointData[] = [];
	let sequence = 0;
	for (let i = 0; i < points.length - 1; i += 1) {
		out.push(points[i]);
		for (const nav of biased_route(
			{ x: points[i].x, z: points[i].y },
			{ x: points[i + 1].x, z: points[i + 1].y },
			side,
		)) {
			sequence += 1;
			out.push({
				type: "Turning Point",
				action: "Turning Point",
				alt: opts.alt ?? DEFAULT_NAV_ALTITUDE_METRES,
				alt_type: opts.alt_type ?? "BARO",
				speed: opts.speed ?? DEFAULT_NAV_SPEED_METRES_PER_SECOND,
				ETA: 0,
				ETA_locked: false,
				x: nav.x,
				y: nav.z,
				name: `${opts.name ?? "Nav"}${sequence}`,
				formation_template: "",
			});
		}
	}
	out.push(points[points.length - 1]);
	return out;
}
