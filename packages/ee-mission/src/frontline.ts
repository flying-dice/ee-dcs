/** @noSelfInFile */
/*
-- frontline.lua
-- EECH source: aphavoc/source/ai/frontl/ai_fline.c
--   create_frontline(force) line 125  — iterates all sectors, marks PRIMARY if check passes
--   check_sector_frontline(side, x, z) line 177 — returns PRIMARY if sector owned by side
--     AND any of its 8 adjacent (3×3 neighbourhood) sectors is owned by a different side
--   recreate_frontline / recreate_side_frontline line 383 — event-driven on capture
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--   add_high_level_ai_function(create_frontline, ...) — periodic rebuild
--
-- DCS proxy: EECH operates on a 2D sector grid (SECTOR_SIDE_LENGTH ≈ 4096 m).
-- check_sector_frontline (ai_fline.c:177) marks a sector PRIMARY when it is owned
-- by side X and any of its up-to-8 grid neighbours (3×3 box) is owned by a
-- different side. DCS has no sector grid and no static painted ownership; bases
-- (keysites) are our sector proxies. The faithful analogue of "the next sector
-- over is enemy-owned" is a *topological* adjacency between bases, not a fixed
-- metric radius. We use Gabriel-graph adjacency: base B (side X) is frontline iff
-- it is Gabriel-adjacent to at least one enemy base E, i.e. no third base lies
-- inside the circle whose diameter is the segment B–E. This is parameter-free and
-- mirrors "immediate neighbour of a different side" far better than the old
-- invented 200 km radius (spec 06 §SECTOR-F16 — the port's fixed-km threshold is
-- REFUTED as an EECH constant).
--
-- Recompute cadence (spec 06 §SECTOR-F16): EECH's create_frontline runs ONCE per
-- force at campaign load (parser.c:1369) over STATIC painted ownership and is never
-- recomputed during play (recreate_frontline, ai_fline.c:383, has no callers). The
-- port's ownership is DYNAMIC (bases change hands), so the faithful analogue is:
-- build at load + recompute on each capture event. There is NO periodic (120 s)
-- rebuild in EECH — that was an invention. M.recompute() is the capture hook.
--
-- Also provides:
--   M.get_frontline(side)       — sorted list of frontline base names for side
--   M.nearest_enemy(name)       — {name, distance} of nearest enemy base
--   M.echelon_of(pos)           — "frontline" | "second" CAS/BAI/SEAD echelon of a position
--   M.rebuild() / M.recompute() — recompute all flags (load + on capture)
*/
import * as cs from "./campaign_state";
import type { Side, WorldPoint } from "./campaign_types";
import { BLUE, RED } from "./sides";

const S = cs.S;
const flags: Record<number, Record<string, boolean>> = {
	[BLUE]: {},
	[RED]: {},
};
function adjacent(
	a: WorldPoint,
	b: WorldPoint,
	aname: string,
	bname: string,
): boolean {
	const dx = a.x - b.x,
		dz = a.z - b.z,
		d2 = dx * dx + dz * dz;
	if (d2 <= 0) return false;
	for (const [name, pos] of Object.entries(S.base_pos))
		if (name !== aname && name !== bname && S.base_owner[name] !== undefined) {
			const ax = a.x - pos.x,
				az = a.z - pos.z,
				bx = b.x - pos.x,
				bz = b.z - pos.z;
			if (ax * ax + az * az + bx * bx + bz * bz < d2) return false;
		}
	return true;
}
export function rebuild(): void {
	const sides: Side[] = [BLUE, RED];
	for (const side of sides) {
		flags[side] = {};
		const enemy = cs.ENEMY[side];
		for (const [name, owner] of Object.entries(S.base_owner))
			if (owner === side) {
				const pos = S.base_pos[name];
				if (!pos) continue;
				let front = false;
				for (const [enemyName, enemyOwner] of Object.entries(S.base_owner))
					if (enemyOwner === enemy) {
						const enemyPos = S.base_pos[enemyName];
						if (enemyPos && adjacent(pos, enemyPos, name, enemyName)) {
							front = true;
							break;
						}
					}
				flags[side][name] = front;
			}
	}
	const count = (side: Side): number =>
		Object.values(flags[side]).filter((value) => value === true).length;
	cs.dbg(
		"frontline",
		"rebuild: BLUE frontline=%d bases, RED frontline=%d bases",
		count(BLUE),
		count(RED),
	);
}
export function recompute(): void {
	cs.dbg("frontline", "recompute triggered (capture event)");
	rebuild();
}
export function is_frontline(name: string, side: Side): boolean {
	return flags[side]?.[name] === true;
}
export function echelon_of(pos?: WorldPoint): "frontline" | "second" {
	if (!pos) return "second";
	let best: string | undefined,
		distance = math.huge;
	for (const [name, base] of Object.entries(S.base_pos))
		if (S.base_owner[name] !== undefined) {
			const dx = pos.x - base.x,
				dz = pos.z - base.z,
				d2 = dx * dx + dz * dz;
			if (d2 < distance) {
				distance = d2;
				best = name;
			}
		}
	return best && is_frontline(best, S.base_owner[best])
		? "frontline"
		: "second";
}
export interface NearestEnemy {
	name: string;
	distance: number;
}
export function nearest_enemy(name: string): NearestEnemy | undefined {
	const pos = S.base_pos[name],
		owner = S.base_owner[name];
	if (!pos || owner === undefined) return undefined;
	const enemy = cs.ENEMY[owner];
	let best: string | undefined,
		distance = math.huge;
	for (const [candidate, candidateOwner] of Object.entries(S.base_owner))
		if (candidateOwner === enemy) {
			const target = S.base_pos[candidate];
			if (!target) continue;
			const dx = pos.x - target.x,
				dz = pos.z - target.z,
				d2 = dx * dx + dz * dz;
			if (d2 < distance) {
				distance = d2;
				best = candidate;
			}
		}
	return best ? { name: best, distance: Math.sqrt(distance) } : undefined;
}
export function get_frontline(side: Side): string[] {
	const rows: Array<{ name: string; dist: number }> = [];
	for (const [name, flag] of Object.entries(flags[side] ?? {}))
		if (flag)
			rows.push({ name, dist: nearest_enemy(name)?.distance ?? math.huge });
	rows.sort((a, b) => a.dist - b.dist);
	return rows.map((row) => row.name);
}
export function init_and_build(): void {
	rebuild();
}
export function schedule_update(_log_fn?: (message: string) => void): void {
	cs.dbg(
		"frontline",
		"schedule_update called: intentional no-op (EECH computes frontline once at load + on capture, not on a timer — see module header)",
	);
}
